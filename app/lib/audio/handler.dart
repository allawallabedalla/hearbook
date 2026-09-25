import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart'
    show AudioInterruptionEvent, AudioInterruptionType;
import 'package:just_audio/just_audio.dart' as ja;

import '../core/clock.dart';
import '../core/hlc.dart';
import '../core/ids.dart';
import '../data/journal.dart';
import '../data/sync.dart';
import '../domain/asleep_prompt.dart';
import '../domain/auto_rewind.dart';
import '../domain/event.dart';
import '../domain/faden_gestures.dart';
import '../domain/manifest.dart';
import '../domain/pause_reason.dart';
import '../domain/position.dart';
import '../l10n/strings.dart';
import '../signals/awake.dart';
import 'playback_status.dart';
import 'player.dart' show LocalSwap, localSwapFor, streamsFromServer;
import 'undo_hint.dart';

/// What the lock screen / Control Center shows for one chapter file: the
/// book as the big title, author and the chapter underneath -- the
/// chapter's own title ("Thomas Mann · Der Weg nach Davos"), or "Kapitel 4
/// von 24" when the file has none (decision E65).
MediaItem lockScreenItem({
  required String fileHash,
  required int chapter,
  required int chapterCount,
  required int durationMs,
  required String bookTitle,
  String? chapterTitle,
  String? author,
  Uri? artUri,
}) {
  final title = chapterTitle?.trim();
  final chapterText =
      (title == null || title.isEmpty) ? AppStrings.chapterOfTotal(chapter, chapterCount) : title;
  final hasAuthor = author != null && author.trim().isNotEmpty;
  return MediaItem(
    id: fileHash,
    title: bookTitle,
    artist: hasAuthor ? '${author.trim()} · $chapterText' : chapterText,
    album: bookTitle,
    duration: Duration(milliseconds: durationMs),
    artUri: artUri,
  );
}

/// The audio_service integration (docs/ARCHITEKTUR.md section 11:
/// "handler.dart (audio_service)"): background playback, lock-screen
/// controls and media-button handling, built around a just_audio
/// [ja.AudioPlayer]. This is also where every user-intent transport action
/// (PLAY, SEEK via +/-30s, UNDO) is turned into a journal event *before*
/// the actual player action runs (invariant 3), and where the app's own
/// heartbeat (every 5s while playing, invariant 3) and sync triggers
/// (section 6: start, pause, every 60s while playing) live.
///
/// Scope note (M4, done): media-button next/previous map to +/-30s, not to
/// a real "next chapter" skip -- docs/ARCHITEKTUR.md section 9: "Mediatasten:
/// normal Play/Pause, Weiter = +30 s, Zurück = -30 s."
///
/// M5 additions live here too: `AWAKE`/`SLEEP_HINT` (section 9), `PROBE`/
/// `RESUME` for Faden-Suche (section 8) and the Faden-mode media-button
/// gate ("Im Faden-Modus zählt jede Taste als 'kenne ich'") -- see the
/// doc comments on [enterFadenMode], [awake], [sleepHint], [probe],
/// [resumeFromFaden] and [resumeFromStop] below.
class FadenAudioHandler extends BaseAudioHandler {
  /// `handleInterruptions: false` (decision E36): just_audio would otherwise
  /// pause and resume by itself on calls and headphone unplugs, without any
  /// PAUSE/PLAY event. Those arrive through [attachAudioSessionEvents]
  /// instead and go through [pauseFrom]/[playFrom] like every other pause.
  final ja.AudioPlayer _player = ja.AudioPlayer(handleInterruptions: false);
  final Journal journal;
  final Clock clock;
  final String deviceId;

  /// Best-effort sync trigger (section 6); null (offline, no server
  /// configured) is fine. Replaceable at runtime ([syncClient] setter) so a
  /// changed server setting applies without an app restart (E37).
  SyncClient? _syncClient;
  Future<SyncSummary?>? _inFlightSync;
  bool _lastSyncFailed = false;

  /// Whether the most recent sync could not reach the server (e.g. the NAS
  /// is powered off at night); opening a book then doesn't wait for sync.
  bool get lastSyncFailed => _lastSyncFailed;

  Manifest? _manifest;
  List<ja.IndexedAudioSource> _sources = const [];
  String? _bookId;
  String? _manifestId;

  Hlc _hlc = const Hlc(pt: 0, c: 0);
  String? _sessionId;
  bool _sessionActive = false;

  Timer? _heartbeatTimer;
  Timer? _syncTimer;
  StreamSubscription<ja.ProcessingState>? _completionSub;
  final List<StreamSubscription<Object?>> _playerSubs = [];

  int? _lastIndex;
  Duration _lastLocalPosition = Duration.zero;
  final StreamController<Position> _positionController =
      StreamController<Position>.broadcast();
  final StreamController<UndoHint> _undoHintController = StreamController<UndoHint>.broadcast();
  final StreamController<Event> _eventsWrittenController = StreamController<Event>.broadcast();
  final StreamController<Set<String>> _remoteEventsController =
      StreamController<Set<String>>.broadcast();
  final StreamController<int> _chapterAdvancedController = StreamController<int>.broadcast();
  final StreamController<PlaybackStatus> _statusController =
      StreamController<PlaybackStatus>.broadcast();
  PlaybackStatus _status = PlaybackStatus.idle;

  /// The playlist index the last seek/open made this handler expect next,
  /// so an index change it caused is never mistaken for playback running
  /// into the next chapter ([chapterAdvanced]).
  int? _expectedSeekIndex;

  /// Wall time playback was last paused (or, right after [openBook], the
  /// book's newest event), for the auto-rewind on the next play (E32).
  /// Null when nothing should be rewound (explicit positioning since).
  int? _pausedAtWallMs;

  /// Why playback was last paused, for the reason-aware rewind (E80): 30 s
  /// after a lost connection. Survives an app restart through the journal.
  PauseReason? _pauseReason;

  /// Whether CarPlay is the audio output right now (E80), from
  /// [attachAudioSessionEvents]' `carAudio` stream.
  bool _carRoute = false;

  /// Set when an audio-session interruption (a call) paused playback, so
  /// its end resumes it (E36).
  bool _resumeAfterInterruption = false;
  final List<StreamSubscription<Object?>> _sessionSubs = [];

  final AwakeGate _awakeGate;

  /// Where the Faden search stands for the headphone buttons (E85): null
  /// when it does not run.
  FadenRemotePhase? _fadenPhase;
  bool Function() _fadenCanGoEarlier = _never;
  static bool _never() => false;
  final StreamController<RemoteCommand> _fadenAnswerController = StreamController<RemoteCommand>.broadcast();

  /// The listening since the last awake proof, for "Eingeschlafen?"
  /// (decision E84): fed with every event this handler journals.
  final ListeningStretchTracker _stretch = ListeningStretchTracker();
  final StreamController<void> _stretchController = StreamController<void>.broadcast();

  /// Optional hook (decision E86, the audit's finding 1): a play from the
  /// lock screen, Control Center or the headphones while sleep is
  /// suspected starts the Faden search instead of playing. Returns true
  /// when it took the play over. Wired from ui/faden_session.dart.
  Future<bool> Function()? onRemotePlay;

  /// Optional hook: signals/sleep_timer.dart's `extendIfInLastMinute`,
  /// wired from ui/player_screen.dart. Returning true means a media-button
  /// call this handler just received was consumed as a timer extension
  /// (docs/KONZEPT.md "Nachtmodus": "In der letzten Minute verlängert jede
  /// Kopfhörertaste den Timer ... statt zu pausieren, und zählt als
  /// Wach-Beleg") instead of running its normal transport action. Left
  /// null (default) when no sleep timer applies (e.g. in tests).
  bool Function()? onLastMinuteExtend;

  FadenAudioHandler({
    required this.journal,
    required this.deviceId,
    SyncClient? syncClient,
    this.clock = const SystemClock(),
    AwakeGate? awakeGate,
  }) : _awakeGate = awakeGate ?? AwakeGate() {
    _wireBroadcast();
    this.syncClient = syncClient;
  }

  SyncClient? get syncClient => _syncClient;

  /// Swaps the sync client (server settings changed, E37). docs/ARCHITEKTUR.md
  /// section 5 receive rule: every pulled remote event advances this
  /// device's clock before it is stored locally, so no later local event
  /// can sort before an event this device already knows.
  set syncClient(SyncClient? client) {
    final old = _syncClient;
    if (identical(old, client)) return;
    if (old != null && old.onRemoteHlc == observeHlc) old.onRemoteHlc = null;
    _syncClient = client;
    client?.onRemoteHlc = observeHlc;
  }

  /// Routes the audio session's interruptions (a call, Siri, an alarm) and
  /// "becoming noisy" (the output went away: headphones unplugged,
  /// Bluetooth or CarPlay disconnected) through the journaled
  /// [pauseFrom]/[playFrom] (decision E36), each with its pause reason
  /// (E80). [carAudio] tells whether CarPlay is the output. main.dart passes
  /// `AudioSession.instance`'s streams; tests pass their own.
  void attachAudioSessionEvents({
    required Stream<AudioInterruptionEvent> interruptions,
    required Stream<void> becomingNoisy,
    Stream<bool>? carAudio,
  }) {
    for (final sub in _sessionSubs) {
      unawaited(sub.cancel());
    }
    _sessionSubs
      ..clear()
      ..add(interruptions.listen(_onInterruption))
      ..add(becomingNoisy.listen((_) => _onBecomingNoisy()));
    if (carAudio != null) _sessionSubs.add(carAudio.listen((car) => _carRoute = car));
  }

  void _onInterruption(AudioInterruptionEvent event) {
    if (event.begin) {
      switch (event.type) {
        case AudioInterruptionType.pause:
        case AudioInterruptionType.unknown:
          if (!playing) return;
          unawaited(pauseFrom(EventSource.system, reason: PauseReason.interruption).then((_) {
            // Set after the pause: a pause always clears it (see pauseFrom).
            // Only a "pause" interruption promises an end event; "unknown"
            // may last forever, so it never resumes by itself.
            _resumeAfterInterruption = event.type == AudioInterruptionType.pause;
          }));
        case AudioInterruptionType.duck:
          // The OS ducks other audio by itself; speech() asks Android to
          // report ducking as a pause instead (androidWillPauseWhenDucked).
          break;
      }
    } else {
      final resume = _resumeAfterInterruption && event.type == AudioInterruptionType.pause;
      _resumeAfterInterruption = false;
      if (resume && !playing) unawaited(playFrom(EventSource.system));
    }
  }

  /// A route change that made the output go away (E80): a lost
  /// connection, never a sleep hint; the next play rewinds 30 s. No
  /// auto-play when it comes back. When a media-button/system pause came
  /// just before (the headphones' own pause, CarPlay's), the rewind still
  /// counts it as a lost connection -- in memory only, the event stays.
  void _onBecomingNoisy() {
    _resumeAfterInterruption = false;
    if (playing) {
      unawaited(pauseFrom(EventSource.system, reason: PauseReason.routeLost));
      return;
    }
    final pausedAt = _pausedAtWallMs;
    if (_pauseReason == PauseReason.unconscious &&
        pausedAt != null &&
        clock.nowMs() - pausedAt <= routeLostFollowUpMs) {
      _pauseReason = PauseReason.routeLost;
    }
  }

  /// How soon after an unconscious pause a lost connection still counts as
  /// its cause, for the rewind (E80).
  static const int routeLostFollowUpMs = 10 * 1000;

  /// Applies the HLC receive rule (docs/ARCHITEKTUR.md section 5) for an
  /// event this device learned about (pulled from the server, or already
  /// in the local journal), if it is ahead of the local clock. Afterwards
  /// every locally generated event sorts after [remote].
  void observeHlc(Hlc remote) {
    if (remote.compareTo(_hlc) <= 0) return;
    _hlc = _hlc.receive(remote, clock.nowMs());
  }

  /// Current playback position as `(file_hash, offset_ms)` -- null before
  /// [openBook] or before the player has reported an index yet.
  Stream<Position> get positionStream => _positionController.stream;

  /// Emits after any jump over 2 min triggered through this handler
  /// (invariant 6 / docs/KONZEPT.md Texte-Tabelle "Zurück zu Kapitel 7,
  /// 23:41"). The UI (ui/player_screen.dart) shows it as a dismissible
  /// banner whose action calls [undo].
  Stream<UndoHint> get undoHints => _undoHintController.stream;

  /// Emits every event right after it was journaled, so the UI can re-run
  /// the Resolver (domain/resolver.dart) and refresh derived state
  /// (history, `finished`, `needs_confirmation`, ...) without this handler
  /// duplicating any of that logic itself. Carries the event so listeners
  /// can skip what does not change derived state (HEARTBEAT, E40).
  Stream<Event> get eventsWritten => _eventsWrittenController.stream;

  /// Emits the book ids a sync pulled events for that were new to this
  /// device (another device listened). ui/providers.dart re-resolves the
  /// open book and calls [adoptRemotePosition] (E31).
  Stream<Set<String>> get remoteEventsPulled => _remoteEventsController.stream;

  /// Emits the new playlist index whenever playback runs into the next
  /// chapter on its own (not after a seek) -- the "Kapitelende" sleep timer.
  Stream<int> get chapterAdvanced => _chapterAdvancedController.stream;

  /// Playing / buffering / last playback error for the UI (E39).
  Stream<PlaybackStatus> get statusStream => _statusController.stream;
  PlaybackStatus get status => _status;

  /// The book currently prepared in the player, if any.
  String? get bookId => _bookId;
  Manifest? get manifest => _manifest;

  /// Prepares [manifest]'s playlist and seeks to [initialPosition], paused
  /// (docs/ARCHITEKTUR.md section 11: "App-Start: Resolver ausfuehren,
  /// Player an der Position pausiert vorbereiten"). Call once per opened
  /// book, after resolving its [domain.BookState] with the Resolver.
  ///
  /// A book that is still playing is paused first, journaled with a PAUSE
  /// for that book (E41) -- otherwise its session would never end and the
  /// new book would start without its own PLAY. [speed] is the new book's
  /// own speed (E38). [syncAfterOpen] is false when the caller already
  /// synced right before resolving (ui/providers.dart).
  Future<void> openBook({
    required String bookId,
    required Manifest manifest,
    required String bookTitle,
    required List<ja.IndexedAudioSource> sources,
    required Position initialPosition,
    String? author,
    Uri? artUri,
    double? speed,
    bool syncAfterOpen = true,
  }) async {
    if (playing && _bookId != null) await pauseFrom(EventSource.ui);
    await _completionSub?.cancel();
    _bookId = bookId;
    _manifestId = manifest.manifestId;
    _manifest = manifest;
    _sources = sources;
    _sessionId = null;
    _sessionActive = false;
    _resumeAfterInterruption = false;
    _lastIndex = null;
    // E93: the listening since the last touch survives an app restart --
    // rebuilt from this device's events of the book.
    try {
      final own = [
        for (final e in await journal.eventsForBook(bookId))
          if (e.deviceId == deviceId) e,
      ];
      _stretch.restore(own, globalMsOf: (e) => manifest.globalMsFor(e.position));
    } catch (_) {
      _stretch.reset();
    }
    if (!_stretchController.isClosed) _stretchController.add(null);
    _setStatus(_status.copyWith(clearError: true));
    // Fold in the newest HLC of every stored event (own and remote), not
    // just this device's own: never lowers a clock already advanced by a
    // concurrent sync pull (observeHlc only moves forward).
    observeHlc(await journal.maxHlc());
    // A pause that spans an app restart still rewinds on the next play,
    // 30 s after a lost connection (E80).
    _pausedAtWallMs = await journal.lastWallMsForBook(bookId);
    _pauseReason = await journal.lastPauseReasonForBook(bookId);

    var initialIndex = manifest.files.indexWhere((f) => f.fileHash == initialPosition.fileHash);
    if (initialIndex == -1) initialIndex = 0; // needs_confirmation: start at chapter 1

    _expectedSeekIndex = initialIndex;
    try {
      await _player.setAudioSources(
        sources,
        initialIndex: initialIndex,
        initialPosition: Duration(milliseconds: initialPosition.offsetMs),
      );
    } on ja.PlayerException catch (e) {
      // E.g. a book that is not downloaded, opened offline: it still opens
      // at its position (lock screen, details, history); the UI shows the
      // error, and the next play loads again (E39).
      _setStatus(_status.copyWith(error: _failure(e, fallbackIndex: initialIndex)));
    } on ja.PlayerInterruptedException {
      // Another load replaced this one (a quick second book switch).
    }
    if (speed != null) await _player.setSpeed(speed);
    _lastIndex = initialIndex;
    _lastLocalPosition = Duration(milliseconds: initialPosition.offsetMs);
    _emitPosition();

    _completionSub = _player.processingStateStream.listen((state) {
      if (state == ja.ProcessingState.completed) unawaited(_onPlaybackCompleted());
    });

    queue.add([
      for (final file in manifest.files)
        lockScreenItem(
          fileHash: file.fileHash,
          chapter: file.idx + 1,
          chapterCount: manifest.files.length,
          durationMs: file.durationMs,
          bookTitle: bookTitle,
          chapterTitle: file.title,
          author: author,
          artUri: artUri,
        ),
    ]);
    mediaItem.add(queue.value[initialIndex]);

    if (syncAfterOpen) unawaited(_sync());
  }

  Position currentPosition() => _currentPosition();

  Future<void> _swaps = Future.value();

  /// A chapter of the loaded book finished downloading (decision E66):
  /// a chapter still ahead plays from [local] from now on, instead of the
  /// stream. The chapter playing now keeps streaming (switching would
  /// interrupt it), except after a playback error, when the next play
  /// loads the list again anyway (E39). One switch at a time.
  Future<void> useDownloadedFile(String bookId, String fileHash, ja.IndexedAudioSource local) {
    return _swaps = _swaps.then((_) => _useDownloadedFile(bookId, fileHash, local)).catchError((Object _) {});
  }

  Future<void> _useDownloadedFile(String bookId, String fileHash, ja.IndexedAudioSource local) async {
    final manifest = _manifest;
    if (_bookId != bookId || manifest == null) return;
    final index = manifest.indexOf(fileHash);
    final swap = localSwapFor(
      index: index,
      length: _sources.length,
      streaming: streamsFromServer(_sources, index),
      currentIndex: _player.currentIndex,
      playerIdle: _player.processingState == ja.ProcessingState.idle,
    );
    switch (swap) {
      case LocalSwap.none:
        return;
      case LocalSwap.listOnly:
        _sources[index] = local;
      case LocalSwap.inPlayer:
        // Insert first, then drop the stream entry: both lie after the
        // current index, so it never moves (no false chapter change).
        await _player.insertAudioSource(index, local);
        await _player.removeAudioSourceAt(index + 1);
        if (_bookId == bookId) _sources[index] = local;
    }
  }

  Position _currentPosition() {
    final manifest = _manifest;
    final idx = _lastIndex;
    if (manifest == null || idx == null || idx < 0 || idx >= manifest.files.length) {
      return const Position(fileHash: '', offsetMs: 0);
    }
    return Position(fileHash: manifest.files[idx].fileHash, offsetMs: _lastLocalPosition.inMilliseconds);
  }

  @override
  Future<void> play() async {
    if (await _interceptMediaButton(RemoteCommand.play)) return;
    final hook = onRemotePlay;
    if (hook != null && !playing && await hook()) return;
    await playFrom(EventSource.system);
  }

  /// Like [play], but lets the caller pick the event `source`. The on-screen
  /// main button ([playPause]) calls this explicitly with `source: ui`
  /// rather than going through the ambiguous [play] override, which the
  /// platform also calls for hardware/system-originated play requests
  /// (headset button, lock-screen control, ...) with no way to tell those
  /// apart from here -- see the doc comment on [pauseFrom] for the same
  /// reasoning on the pause side.
  ///
  /// Auto-rewind (E32, domain/auto_rewind.dart): after a pause of 10 s or
  /// more, playback resumes a little earlier, and that earlier position is
  /// the PLAY event's own position (never a separate jump; always < 2 min).
  /// Not applied after an explicit seek while paused, nor for Faden-Suche
  /// results or "Ab Stopp weiterhören" ([resumeFromFaden]/[resumeFromStop],
  /// which position themselves).
  Future<void> playFrom(EventSource source) async {
    _resumeAfterInterruption = false;
    var position = _currentPosition();
    int? rewindIndex;
    final manifest = _manifest;
    final pausedAt = _pausedAtWallMs;
    if (manifest != null && pausedAt != null && !playing) {
      final globalMs = manifest.globalMsFor(position);
      if (globalMs != null) {
        final target = autoRewoundGlobalMs(
          globalMs: globalMs,
          pausedForMs: clock.nowMs() - pausedAt,
          reason: _pauseReason,
        );
        if (target != globalMs) {
          position = manifest.positionForGlobalMs(target);
          rewindIndex = manifest.indexOf(position.fileHash);
        }
      }
    }
    _pausedAtWallMs = null;
    _pauseReason = null;
    final event = _buildEvent(type: EventType.play, position: position, source: source);
    final target = position;
    await _journal(event, () async {
      await _reloadIfIdleAfterError(target);
      if (rewindIndex != null && rewindIndex >= 0) await _seekPlayer(target, rewindIndex);
      _setStatus(_status.copyWith(clearError: true));
      _startPlayback();
    });
    _startHeartbeat();
    _startPeriodicSync();
  }

  /// After a playback error the player sits idle with nothing loaded; a
  /// new play then reloads the playlist at [at] first (E39).
  Future<void> _reloadIfIdleAfterError(Position at) async {
    if (_status.error == null || _sources.isEmpty) return;
    if (_player.processingState != ja.ProcessingState.idle) return;
    final manifest = _manifest;
    final idx = manifest?.indexOf(at.fileHash) ?? -1;
    if (idx < 0) return;
    _expectedSeekIndex = idx;
    try {
      await _player.setAudioSources(
        _sources,
        initialIndex: idx,
        initialPosition: Duration(milliseconds: at.offsetMs),
      );
    } catch (_) {
      // The error listener reports it again; the button stays usable.
    }
  }

  /// Starts the main player without awaiting just_audio's `play()` future,
  /// which only completes once playback is paused or completed again --
  /// awaiting it would hold back everything after it (heartbeat, periodic
  /// sync, the undo hint, the Faden screen's result state) for the whole
  /// playback.
  void _startPlayback() => unawaited(_player.play());

  @override
  Future<void> pause() async {
    if (await _interceptMediaButton(RemoteCommand.pause)) return;
    await pauseFrom(EventSource.system);
  }

  /// Like [pause], but lets the caller pick the event `source` -- a sleep
  /// timer expiry (signals/sleep_timer.dart) pauses with `source: timer`,
  /// which docs/ARCHITEKTUR.md section 5 / domain/event.dart deliberately
  /// does *not* count as an awake-proof, unlike a UI pause. The on-screen
  /// main button ([playPause]) calls this explicitly with `source: ui`; the
  /// bare [pause] override (the platform's own entry point -- headset
  /// button, lock-screen/notification control, AirPods sleep detection,
  /// ...) has no way to tell those origins apart, so it uses `source:
  /// system` uniformly (section 9: "von einem bewussten Tastendruck nicht
  /// zu unterscheiden").
  ///
  /// [reason] (decision E80) defaults from the source
  /// (domain/pause_reason.dart); a lost connection and an interruption pass
  /// their own. It goes into the PAUSE event's `data`, together with the
  /// car route while CarPlay is the output, and decides whether a
  /// `SLEEP_HINT` follows: after an unconscious pause at any time of day
  /// (not in the car), after the sleep timer always, otherwise never.
  Future<void> pauseFrom(EventSource source, {PauseReason? reason}) =>
      _pause(source, reason: reason ?? defaultPauseReason(source));

  Future<void> _pause(EventSource source, {required PauseReason reason}) async {
    _resumeAfterInterruption = false;
    if (playing || _pausedAtWallMs == null) {
      _pausedAtWallMs = clock.nowMs();
      _pauseReason = reason;
    }
    final position = _currentPosition();
    final car = _carRoute;
    final event = _buildEvent(
      type: EventType.pause,
      position: position,
      source: source,
      data: pauseData(reason, carRoute: car),
    );
    await _journal(event, _player.pause);
    _sessionActive = false;
    _stopHeartbeat();
    _stopPeriodicSync();
    unawaited(_sync());
    if (writesSleepHint(reason, carRoute: car)) await sleepHint(source: source);
  }

  Future<void> playPause() => playing ? pauseFrom(EventSource.ui) : playFrom(EventSource.ui);

  /// "Eingeschlafen?" -> "Ja, Stelle suchen" (decision E84): stops the
  /// book the listener slept through, journaled first. Neither the pause
  /// nor what follows is an awake proof: a PAUSE with `source=faden`,
  /// reason `unconscious`, and a SLEEP_HINT (the listener just said so),
  /// so an aborted search leaves the suspicion in place. Returns the
  /// stretch as it was, for the search window.
  Future<ListeningStretch> pauseForAsleepSearch() async {
    final stretch = this.stretch;
    if (playing) await _pause(EventSource.faden, reason: PauseReason.unconscious);
    return stretch;
  }

  /// The listening since the last awake proof (E84), now.
  ListeningStretch get stretch => _stretch.snapshot(clock.nowMs());

  /// Emits whenever [stretch] may have changed its state (an event was
  /// journaled, another book opened).
  Stream<void> get stretchChanges => _stretchController.stream;

  /// Whether CarPlay is the audio output right now (E80).
  bool get carRoute => _carRoute;

  /// The session the last events belong to (the one a listener fell asleep
  /// in, after its stop), or null before anything was journaled.
  String? get sessionId => _sessionId;

  /// docs/ARCHITEKTUR.md section 9: hardware media buttons "Weiter" /
  /// "Zurück" are +/-30s, not a chapter skip.
  @override
  Future<void> skipToNext() async {
    if (await _interceptMediaButton(RemoteCommand.next)) return;
    await seekBySeconds(30, source: EventSource.mediaButton);
  }

  @override
  Future<void> skipToPrevious() async {
    if (await _interceptMediaButton(RemoteCommand.previous)) return;
    await seekBySeconds(-30, source: EventSource.mediaButton);
  }

  @override
  Future<void> fastForward() async {
    if (await _interceptMediaButton(RemoteCommand.fastForward)) return;
    await seekBySeconds(30, source: EventSource.mediaButton);
  }

  @override
  Future<void> rewind() async {
    if (await _interceptMediaButton(RemoteCommand.rewind)) return;
    await seekBySeconds(-30, source: EventSource.mediaButton);
  }

  /// Faden-Suche mode (docs/ARCHITEKTUR.md sections 8/9). While active,
  /// every hardware/system media-button call this handler can receive --
  /// on iOS, the remote command center calls [play]/[pause]/[skipToNext]/
  /// [skipToPrevious] directly; on Android, a physical headset-hook click
  /// reaches the very same four through [BaseAudioHandler]'s own default
  /// `click()` (unmodified here), and a multi-button remote can additionally
  /// reach [fastForward]/[rewind] -- counts as "kenne ich" instead of
  /// performing its normal transport action (docs/KONZEPT.md: "Kopfhörertaste
  /// ... Im Faden-Modus zählt jede [Media-]Taste als 'kenne ich'"). Gating
  /// all six overrides here is therefore the single choke point both
  /// platforms' event paths funnel through. ui/faden_screen.dart never
  /// renders transport controls while this is true, so any call received
  /// here during Faden mode is, by construction, hardware/system-originated,
  /// never our own on-screen UI.
  ///
  /// Decision E85: each button now means something of its own
  /// (domain/faden_gestures.dart): 1x "Kenne ich", 2x "Kenne ich nicht",
  /// 3x "Nochmal hören"; the command goes out on [fadenModeAnswers].
  void enterFadenMode() {
    _fadenPhase = FadenRemotePhase.search;
    _fadenCanGoEarlier = _never;
  }

  /// The result plays (E85): the buttons act normally again, except 3x
  /// ("Etwas früher anfangen") while [canGoEarlier] says there is an
  /// earlier passage.
  void enterFadenResultMode({required bool Function() canGoEarlier}) {
    _fadenPhase = FadenRemotePhase.result;
    _fadenCanGoEarlier = canGoEarlier;
  }

  /// Ends Faden mode (search resolved, aborted, or the screen closed).
  void exitFadenMode() {
    _fadenPhase = null;
    _fadenCanGoEarlier = _never;
  }

  /// Whether probes are being asked (every button is an answer).
  bool get fadenModeActive => _fadenPhase == FadenRemotePhase.search;

  /// Whether a Faden search runs or shows its result.
  bool get fadenSearchRunning => _fadenPhase != null;

  /// Emits the command of every button press Faden mode took over.
  /// ui/faden_session.dart maps it to an answer ([fadenGestureFor]).
  Stream<RemoteCommand> get fadenModeAnswers => _fadenAnswerController.stream;

  bool _consumeAsFadenAnswer(RemoteCommand command) {
    final phase = _fadenPhase;
    if (phase == null) return false;
    if (fadenGestureFor(command, phase, canGoEarlier: _fadenCanGoEarlier()) == null) return false;
    _fadenAnswerController.add(command);
    return true;
  }

  Future<bool> _consumeAsLastMinuteExtend() async {
    final extend = onLastMinuteExtend;
    if (extend == null || !extend()) return false;
    await awake(source: EventSource.mediaButton);
    return true;
  }

  /// Runs the Faden-mode gate, then the last-minute sleep-timer-extend
  /// hook, in that order (Faden mode and a running sleep timer are not
  /// expected to overlap in practice, but Faden mode is the more specific
  /// state). Returns true if either consumed the call, in which case the
  /// caller must skip its normal transport action.
  Future<bool> _interceptMediaButton(RemoteCommand command) async {
    if (_consumeAsFadenAnswer(command)) return true;
    return _consumeAsLastMinuteExtend();
  }

  /// docs/ARCHITEKTUR.md section 5: writes an `AWAKE` event, throttled by
  /// [_awakeGate] to at most one per 10s combined across every trigger
  /// (screen touch, volume change, timer extension -- section 9). A no-op
  /// (returns false) while the cooldown hasn't elapsed yet.
  ///
  /// While nothing plays, the event gets a session of its own (decision
  /// E83): a touch in the morning proves the listener is awake now, not
  /// that they heard the end of the session they fell asleep in -- it must
  /// not clear the sleep suspicion before "Faden aufnehmen" (it still marks
  /// when they woke up, E79).
  Future<bool> awake({EventSource source = EventSource.ui}) async {
    if (!_awakeGate.shouldEmit(clock.nowMs())) return false;
    final event = _buildEvent(
      type: EventType.awake,
      position: _currentPosition(),
      source: source,
      detached: !_sessionActive,
    );
    await _journal(event, () async {});
    return true;
  }

  /// docs/ARCHITEKTUR.md section 9: writes a `SLEEP_HINT` event. Never
  /// rate-limited (unlike [awake]) -- section 5's table gives `AWAKE` alone
  /// the "höchstens 1 pro 10 s" qualifier.
  Future<void> sleepHint({required EventSource source}) async {
    final event = _buildEvent(type: EventType.sleepHint, position: _currentPosition(), source: source);
    await _journal(event, () async {});
  }

  /// Sleep-timer expiry (signals/sleep_timer.dart's `onExpire`): `PAUSE`/
  /// `source=timer` plus `SLEEP_HINT` (docs/ARCHITEKTUR.md section 9:
  /// "SLEEP_HINT entsteht beim Ablauf des Sleep-Timers"), both through
  /// [pauseFrom] with the timer reason.
  Future<void> pauseForSleepTimerExpiry() => pauseFrom(EventSource.timer);

  /// docs/ARCHITEKTUR.md section 8 closing note: "Jede Probe wird als
  /// PROBE-Event geschrieben". [known] is the listener's answer ("kenne
  /// ich" / "kenne ich nicht"), stored verbatim in `data.known` per section
  /// 5. Never touches the main player (the probe itself plays on a separate
  /// audio/probe_player.dart instance, docs/ARCHITEKTUR.md section 8:
  /// "Proben laufen über einen eigenen Player") and is never awake-proof or
  /// session-opening (domain/event.dart's `EventType.probe` already
  /// excludes it from both `isAwakeProof` and `isIntent`).
  Future<void> probe({required Position position, required bool known}) async {
    final event = _buildEvent(
      type: EventType.probe,
      position: position,
      source: EventSource.faden,
      data: {'known': known},
    );
    await _journal(event, () async {});
  }

  /// docs/ARCHITEKTUR.md section 8 closing note: "das Ergebnis als
  /// RESUME-Event" -- both the search's own finding and each subsequent
  /// "Früher" ladder step (docs/KONZEPT.md Texte-Tabelle: "Leiter |
  /// Früher") call this. [fileIndex] is the caller's already-resolved index
  /// of [target] in the active manifest (ui/faden_screen.dart already holds
  /// that `Manifest`, so this stays independent of whether [openBook] ever
  /// ran -- see docs/ARCHITEKTUR.md section 13 for why). Seeks the main
  /// player there and starts playback (docs/KONZEPT.md: "Die Wiedergabe
  /// startet am letzten erkannten Satz.").
  Future<void> resumeFromFaden(Position target, {required int? fileIndex}) =>
      _resumeTo(target, fileIndex: fileIndex, source: EventSource.faden, fromFaden: true);

  /// docs/KONZEPT.md "Faden aufnehmen": "Ab Stopp weiterhören" -- skips the
  /// search entirely and resumes exactly at the stop point (shown as a
  /// small line under the main button once `sleep_suspected` is true).
  Future<void> resumeFromStop(Position target, {required int? fileIndex}) =>
      _resumeTo(target, fileIndex: fileIndex, source: EventSource.ui);

  Future<void> _resumeTo(
    Position target, {
    required int? fileIndex,
    required EventSource source,
    bool fromFaden = false,
  }) async {
    // Invariant 6: a RESUME after falling asleep opens a new session, so the
    // Resolver's history (rule 6, winning session only) never records this
    // jump -- the undo hint is the one-tap way back to where playback stood.
    final manifest = _manifest;
    final from = _currentPosition();
    final fromGlobalMs = manifest?.globalMsFor(from);
    final toGlobalMs = manifest?.globalMsFor(target);
    _pausedAtWallMs = null; // positions itself: no auto-rewind (E32)
    final event = _buildEvent(type: EventType.resume, position: target, source: source);
    await _journal(event, () async {
      await _reloadIfIdleAfterError(target);
      await _seekPlayer(target, fileIndex);
      _setStatus(_status.copyWith(clearError: true));
    });
    if (manifest != null && fromGlobalMs != null && toGlobalMs != null) {
      var hint =
          undoHintForJump(from: from, fromGlobalMs: fromGlobalMs, toGlobalMs: toGlobalMs, manifest: manifest);
      // E89: after the Faden search, the way back is "where it stopped".
      if (hint != null && fromFaden) hint = UndoHint.fromFaden(hint.target);
      if (hint != null) _undoHintController.add(hint);
    }
    _startPlayback();
    _startHeartbeat();
    _startPeriodicSync();
  }

  /// The on-screen +/-30s buttons (docs/ARCHITEKTUR.md section 11: "+/-30
  /// s") call this with `source: ui`.
  Future<void> seekBySeconds(int deltaSeconds, {EventSource source = EventSource.ui}) async {
    final manifest = _manifest;
    if (manifest == null) return;
    final fromGlobalMs = manifest.globalMsFor(_currentPosition());
    if (fromGlobalMs == null) return;
    final toGlobalMs = (fromGlobalMs + deltaSeconds * 1000).clamp(0, manifest.totalDurationMs);
    await _seekToGlobalMs(toGlobalMs, source: source);
  }

  /// Absolute seek (chapter tap, scrubber, history/"Verlauf" entry).
  Future<void> seekToGlobalMs(int globalMs, {EventSource source = EventSource.ui}) =>
      _seekToGlobalMs(globalMs, source: source);

  Future<void> seekToChapterStart(int chapterIdx) {
    final manifest = _manifest;
    if (manifest == null) return Future.value();
    final start = manifest.files.take(chapterIdx).fold(0, (sum, f) => sum + f.durationMs);
    return _seekToGlobalMs(start, source: EventSource.ui);
  }

  Future<void> _seekToGlobalMs(int globalMs, {required EventSource source}) async {
    final manifest = _manifest;
    if (manifest == null || manifest.files.isEmpty) return;
    final clamped = globalMs.clamp(0, manifest.totalDurationMs);
    await _seekToPosition(manifest.positionForGlobalMs(clamped), source: source);
  }

  /// The one SEEK path: journal first (invariant 3), then move the player,
  /// then the undo hint for a jump over 2 min (invariant 6).
  Future<void> _seekToPosition(Position target, {required EventSource source}) async {
    final manifest = _manifest;
    if (manifest == null) return;
    final from = _currentPosition();
    final fromGlobalMs = manifest.globalMsFor(from);
    final toGlobalMs = manifest.globalMsFor(target);
    final idx = manifest.indexOf(target.fileHash);
    _pausedAtWallMs = null; // an explicit position: no auto-rewind (E32)
    final event = _buildEvent(type: EventType.seek, position: target, source: source);
    await _journal(event, () => _seekPlayer(target, idx < 0 ? null : idx));
    if (fromGlobalMs != null && toGlobalMs != null) {
      final hint =
          undoHintForJump(from: from, fromGlobalMs: fromGlobalMs, toGlobalMs: toGlobalMs, manifest: manifest);
      if (hint != null) _undoHintController.add(hint);
    }
  }

  /// Lock-screen / Control Center scrubber (decision E43): [position] is
  /// within the current chapter (the lock screen shows one chapter as the
  /// item). A journaled SEEK with the same undo hint as every other seek.
  /// Ignored in Faden mode, where the main player is not what plays.
  @override
  Future<void> seek(Duration position) async {
    if (fadenModeActive) return;
    final manifest = _manifest;
    final idx = _lastIndex;
    if (manifest == null || idx == null || idx < 0 || idx >= manifest.files.length) return;
    final file = manifest.files[idx];
    final offsetMs = position.inMilliseconds.clamp(0, file.durationMs);
    await _seekToPosition(Position(fileHash: file.fileHash, offsetMs: offsetMs), source: EventSource.system);
  }

  /// Moves the main player and updates the locally known position at once
  /// (the player's own streams confirm it shortly after), so a second
  /// action right after this one starts from the new position.
  Future<void> _seekPlayer(Position target, int? index) async {
    if (index != null) _expectedSeekIndex = index;
    await _player.seek(Duration(milliseconds: target.offsetMs), index: index);
    final manifest = _manifest;
    final idx = index ?? _lastIndex;
    if (manifest != null &&
        idx != null &&
        idx >= 0 &&
        idx < manifest.files.length &&
        manifest.files[idx].fileHash == target.fileHash) {
      if (idx != _lastIndex && queue.value.length > idx) mediaItem.add(queue.value[idx]);
      _lastIndex = idx;
      _lastLocalPosition = Duration(milliseconds: target.offsetMs);
      _emitPosition();
    }
  }

  /// Follows positions another device set (decision E31): after a sync
  /// pulled new events for the open book while nothing plays,
  /// ui/providers.dart re-resolves and hands the resolved position here.
  /// Moves the prepared player there without an event of its own -- the
  /// remote events that decided it are already journaled -- and, for a
  /// jump over 2 min, emits an undo hint back to where the player stood
  /// (invariant 6), whose UNDO then wins as the newest intent. Returns
  /// whether the player moved.
  Future<bool> adoptRemotePosition(Position target) async {
    final manifest = _manifest;
    if (manifest == null || playing || fadenSearchRunning) return false;
    final idx = manifest.indexOf(target.fileHash);
    if (idx < 0) return false;
    final from = _currentPosition();
    if (from == target) return false;
    await _seekPlayer(target, idx);
    final fromGlobalMs = manifest.globalMsFor(from);
    final toGlobalMs = manifest.globalMsFor(target);
    if (fromGlobalMs != null && toGlobalMs != null && isUndoWorthyJump(fromGlobalMs, toGlobalMs)) {
      _undoHintController.add(UndoHint(target: from, message: AppStrings.remotePositionAdopted));
    }
    return true;
  }

  /// "Rückgängig" (invariant 6) / a tap on a "Verlauf" (history) entry:
  /// jumps back to [target] as an `UNDO` event, per docs/ARCHITEKTUR.md
  /// section 5 ("UNDO | Rückgängig, 'Früher'").
  Future<void> undo(Position target) async {
    final manifest = _manifest;
    if (manifest == null) return;
    final idx = manifest.files.indexWhere((f) => f.fileHash == target.fileHash);
    _pausedAtWallMs = null; // an explicit position: no auto-rewind (E32)
    final event = _buildEvent(type: EventType.undo, position: target, source: EventSource.ui);
    await _journal(event, () => _seekPlayer(target, idx < 0 ? null : idx));
  }

  /// Not journaled (docs/ARCHITEKTUR.md section 5 has no event for it);
  /// ui/providers.dart persists it per book (E38).
  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  /// Wall-clock time until the current chapter ends at the current speed
  /// (the "Kapitelende" sleep timer's countdown and fade).
  Duration chapterRemaining() {
    final manifest = _manifest;
    final idx = _lastIndex;
    if (manifest == null || idx == null || idx < 0 || idx >= manifest.files.length) return Duration.zero;
    final remainingMs = (manifest.files[idx].durationMs - _lastLocalPosition.inMilliseconds)
        .clamp(0, manifest.files[idx].durationMs);
    final speed = _player.speed <= 0 ? 1.0 : _player.speed;
    return Duration(milliseconds: (remainingMs / speed).round());
  }

  /// Volume fade during the sleep timer's last 30s (signals/sleep_timer.dart);
  /// deliberately not journaled -- it is a local playback effect, not a
  /// position change.
  Future<void> setSleepFadeVolume(double factor) => _player.setVolume(factor);

  Future<void> _onPlaybackCompleted() async {
    _stopHeartbeat();
    _stopPeriodicSync();
    _sessionActive = false;
    final position = _currentPosition();
    // Section 5: FINISHED carries no intent of its own weight beyond
    // being the winning session's last event; whether it actually counts
    // as "finished" (rule 7: only without sleep_suspected) is entirely the
    // Resolver's call, already implemented in domain/resolver.dart -- this
    // handler does not (and, per the M4 task scope, must not) re-derive
    // sleep-suspicion itself. Invariant 5 ("nie automatisch ins naechste
    // Buch") holds by construction: the playlist is always exactly one
    // book's manifest, so there is no next book to advance into.
    // E92: in the car the end was not slept through.
    final event = _buildEvent(
      type: EventType.finished,
      position: position,
      source: EventSource.system,
      data: _carRoute ? const {'route': carRouteName} : const {},
    );
    await _journal(event, () async {});
    unawaited(_sync());
  }

  /// "Eingeschlafen?" -> "Nein" after the book ended by itself (decision
  /// E92): the listener heard the end. A RESUME at the end (a new session,
  /// awake) and a FINISHED right after it, nothing plays; the Resolver then
  /// calls the book finished (invariant 5) and E57 may clean it up.
  Future<void> confirmBookEnd() async {
    final position = _currentPosition();
    if (position.fileHash.isEmpty) return;
    _pausedAtWallMs = null;
    await _journal(_buildEvent(type: EventType.resume, position: position, source: EventSource.ui), () async {});
    await _journal(_buildEvent(type: EventType.finished, position: position, source: EventSource.ui), () async {});
    _sessionActive = false;
    unawaited(_sync());
  }

  Event _buildEvent({
    required EventType type,
    required Position position,
    required EventSource source,
    Map<String, dynamic> data = const {},
    bool detached = false,
  }) {
    if (type.isIntent && !_sessionActive) {
      _sessionId = Ids.uuid();
      _sessionActive = true;
    }
    _sessionId ??= Ids.uuid();
    _hlc = _hlc.tick(clock.nowMs());
    return Event(
      eventId: Ids.eventId(),
      deviceId: deviceId,
      sessionId: detached ? Ids.uuid() : _sessionId!,
      bookId: _bookId ?? '',
      manifestId: _manifestId ?? '',
      type: type,
      fileHash: position.fileHash,
      offsetMs: position.offsetMs,
      hlc: _hlc,
      wallMs: clock.nowMs(),
      tzMin: clock.tzOffsetMin(),
      source: source,
      data: data,
    );
  }

  Future<T> _journal<T>(Event event, Future<T> Function() action) async {
    final result = await journal.record(event, action);
    if (event.type != EventType.heartbeat) {
      _stretch.onEvent(event, globalMs: _manifest?.globalMsFor(event.position));
      if (!_stretchController.isClosed) _stretchController.add(null);
    }
    if (!_eventsWrittenController.isClosed) _eventsWrittenController.add(event);
    return result;
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (_) => unawaited(_heartbeat()));
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  Future<void> _heartbeat() async {
    if (!_player.playing) return;
    final event =
        _buildEvent(type: EventType.heartbeat, position: _currentPosition(), source: EventSource.ui);
    await _journal(event, () async {});
  }

  void _startPeriodicSync() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(const Duration(seconds: 60), (_) => unawaited(_sync()));
  }

  void _stopPeriodicSync() {
    _syncTimer?.cancel();
    _syncTimer = null;
  }

  Future<void> _sync() => syncNow();

  /// Runs one sync (push, then pull) now; the triggers of docs/ARCHITEKTUR.md
  /// section 6 all end up here (start, foreground, pause, network change,
  /// every 60 s while playing). A sync already running is shared instead of
  /// starting a second one. With [timeout], stops waiting (the sync itself
  /// carries on) and returns null. Never throws: null when offline or no
  /// server is configured.
  Future<SyncSummary?> syncNow({Duration? timeout}) {
    final client = _syncClient;
    if (client == null) return Future.value(null);
    final running = _inFlightSync ??= _runSync(client).whenComplete(() => _inFlightSync = null);
    if (timeout == null) return running;
    return running.timeout(timeout, onTimeout: () => null);
  }

  Future<SyncSummary?> _runSync(SyncClient client) async {
    try {
      final summary = await client.sync();
      _lastSyncFailed = false;
      if (summary.pulledBookIds.isNotEmpty && !_remoteEventsController.isClosed) {
        _remoteEventsController.add(summary.pulledBookIds);
      }
      return summary;
    } catch (_) {
      // Offline: docs/KONZEPT.md Texte-Tabelle "Keine Verbindung zum
      // Server. Geladene Bücher spielen weiter." -- sync failures never
      // interrupt playback.
      _lastSyncFailed = true;
      return null;
    }
  }

  void _wireBroadcast() {
    _playerSubs.add(_player.currentIndexStream.listen((idx) {
      // Null means "no playlist loaded" (between books); the last known
      // chapter stays, so no event is ever written without a file_hash.
      if (idx == null) return;
      final previous = _lastIndex;
      if (isNaturalChapterAdvance(previous: previous, next: idx, expectedSeekIndex: _expectedSeekIndex) &&
          !_chapterAdvancedController.isClosed) {
        _chapterAdvancedController.add(idx);
      }
      if (idx == _expectedSeekIndex) _expectedSeekIndex = null;
      _lastIndex = idx;
      _emitPosition();
      final manifest = _manifest;
      if (manifest != null && idx >= 0 && idx < manifest.files.length) {
        final item = queue.value.length > idx ? queue.value[idx] : null;
        if (item != null) mediaItem.add(item);
      }
    }));
    _playerSubs.add(_player.positionStream.listen((pos) {
      _lastLocalPosition = pos;
      _emitPosition();
    }));
    // Errors arrive on playbackEventStream as error events; without a
    // handler they would be unhandled (E39).
    _playerSubs.add(_player.playbackEventStream.listen(_broadcastState, onError: (Object _) {}));
    _playerSubs.add(_player.errorStream.listen(_onPlayerError));
    _playerSubs.add(_player.playerStateStream.listen((state) {
      _setStatus(_status.copyWith(
        playing: state.playing,
        buffering: isBuffering(playing: state.playing, phase: PlayerPhase.values[state.processingState.index]),
      ));
    }));
  }

  /// A load or playback error (server unreachable while streaming, a broken
  /// file): shown to the UI through [statusStream]; if it stopped playback,
  /// that stop is journaled as a PAUSE like any other (no SLEEP_HINT: it
  /// says nothing about the listener).
  void _onPlayerError(ja.PlayerException e) {
    _setStatus(_status.copyWith(error: _failure(e, fallbackIndex: _lastIndex)));
    playbackState.add(playbackState.value.copyWith(
      processingState: AudioProcessingState.error,
      errorCode: e.code,
      errorMessage: e.message,
    ));
    if (playing) unawaited(_pause(EventSource.system, reason: PauseReason.error));
  }

  /// [e] as a [PlaybackFailure], marked `notDownloaded` when its chapter
  /// streams from the server (decision E58).
  PlaybackFailure _failure(ja.PlayerException e, {int? fallbackIndex}) {
    final index = e.index ?? fallbackIndex;
    return PlaybackFailure(
      code: e.code,
      message: e.message,
      chapterIndex: e.index,
      notDownloaded: streamsFromServer(_sources, index),
    );
  }

  void _setStatus(PlaybackStatus next) {
    if (next == _status) return;
    _status = next;
    if (!_statusController.isClosed) _statusController.add(next);
  }

  void _emitPosition() {
    final manifest = _manifest;
    final idx = _lastIndex;
    if (manifest == null || idx == null || idx < 0 || idx >= manifest.files.length) return;
    _positionController.add(
      Position(fileHash: manifest.files[idx].fileHash, offsetMs: _lastLocalPosition.inMilliseconds),
    );
  }

  void _broadcastState(ja.PlaybackEvent event) {
    final playing = _player.playing;
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.rewind,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.fastForward,
        ],
        systemActions: const {MediaAction.seek},
        processingState: const {
          ja.ProcessingState.idle: AudioProcessingState.idle,
          ja.ProcessingState.loading: AudioProcessingState.loading,
          ja.ProcessingState.buffering: AudioProcessingState.buffering,
          ja.ProcessingState.ready: AudioProcessingState.ready,
          ja.ProcessingState.completed: AudioProcessingState.completed,
        }[_player.processingState]!,
        playing: playing,
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
        queueIndex: _player.currentIndex,
      ),
    );
  }

  @override
  Future<void> stop() async {
    await _player.stop();
    return super.stop();
  }

  Future<void> dispose() async {
    _stopHeartbeat();
    _stopPeriodicSync();
    syncClient = null;
    for (final sub in _sessionSubs) {
      await sub.cancel();
    }
    _sessionSubs.clear();
    // Player listeners first, then the player, and only then the
    // controllers those listeners (and in-flight actions) add to.
    await _completionSub?.cancel();
    for (final sub in _playerSubs) {
      await sub.cancel();
    }
    _playerSubs.clear();
    await _player.dispose();
    await _positionController.close();
    await _undoHintController.close();
    await _eventsWrittenController.close();
    await _fadenAnswerController.close();
    await _stretchController.close();
    await _remoteEventsController.close();
    await _chapterAdvancedController.close();
    await _statusController.close();
  }

  /// Whether audio is currently playing -- ui/player_screen.dart's main
  /// button icon.
  Stream<bool> get playingStream => _player.playingStream;
  bool get playing => _player.playing;

  /// Current playback speed -- ui/details_sheet.dart's Tempo control.
  Stream<double> get speedStream => _player.speedStream;
  double get speed => _player.speed;
}
