import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart' as ja;

import '../core/clock.dart';
import '../core/hlc.dart';
import '../core/ids.dart';
import '../data/journal.dart';
import '../data/sync.dart';
import '../domain/event.dart';
import '../domain/manifest.dart';
import '../domain/position.dart';
import '../l10n/strings.dart';
import '../signals/awake.dart';
import 'undo_hint.dart';

/// What the lock screen / Control Center shows for one chapter file: the
/// book as the big title, author and chapter position underneath.
MediaItem lockScreenItem({
  required String fileHash,
  required int chapter,
  required int chapterCount,
  required int durationMs,
  required String bookTitle,
  String? author,
  Uri? artUri,
}) {
  final chapterText = AppStrings.chapterOfTotal(chapter, chapterCount);
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
  final ja.AudioPlayer _player = ja.AudioPlayer();
  final Journal journal;
  final Clock clock;
  final String deviceId;

  /// Best-effort sync trigger (section 6); optional so the handler still
  /// works (offline) if none is supplied.
  final SyncClient? syncClient;

  Manifest? _manifest;
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
  final StreamController<void> _eventsWrittenController = StreamController<void>.broadcast();

  final AwakeGate _awakeGate;
  bool _fadenModeActive = false;
  final StreamController<void> _fadenAnswerController = StreamController<void>.broadcast();

  /// Optional hook: signals/sleep_timer.dart's `extendIfInLastMinute`,
  /// wired from ui/player_screen.dart. Returning true means a media-button
  /// call this handler just received was consumed as a timer extension
  /// (docs/KONZEPT.md "Nachtmodus": "In der letzten Minute verlängert jede
  /// Kopfhörertaste den Timer ... statt zu pausieren, und zählt als
  /// Wach-Beleg") instead of running its normal transport action. Left
  /// null (default) when no sleep timer applies (e.g. in tests).
  bool Function()? onLastMinuteExtend;

  /// Optional hook: signals/night.dart's `isInNightWindow` evaluated for
  /// "now", wired from ui/player_screen.dart -- decides whether a
  /// media/system pause also writes `SLEEP_HINT` (docs/ARCHITEKTUR.md
  /// section 9). Left null (default) in contexts without a night-window
  /// setting (e.g. tests): such a pause then never counts as a sleep hint,
  /// which is the safe default (no false suspicion).
  bool Function()? isInNightWindow;

  FadenAudioHandler({
    required this.journal,
    required this.deviceId,
    this.syncClient,
    this.clock = const SystemClock(),
    AwakeGate? awakeGate,
  }) : _awakeGate = awakeGate ?? AwakeGate() {
    _wireBroadcast();
    // docs/ARCHITEKTUR.md section 5 receive rule: every pulled remote event
    // advances this device's clock before it is stored locally, so no later
    // local event can sort before an event this device already knows.
    syncClient?.onRemoteHlc = observeHlc;
  }

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

  /// Pings after every journal write, so the UI can re-run the Resolver
  /// (domain/resolver.dart) and refresh derived state (history, `finished`,
  /// `needs_confirmation`, ...) without this handler duplicating any of
  /// that logic itself.
  Stream<void> get eventsWritten => _eventsWrittenController.stream;

  /// Prepares [manifest]'s playlist and seeks to [initialPosition], paused
  /// (docs/ARCHITEKTUR.md section 11: "App-Start: Resolver ausfuehren,
  /// Player an der Position pausiert vorbereiten"). Call once per opened
  /// book, after resolving its [domain.BookState] with the Resolver.
  Future<void> openBook({
    required String bookId,
    required Manifest manifest,
    required String bookTitle,
    required List<ja.IndexedAudioSource> sources,
    required Position initialPosition,
    String? author,
    Uri? artUri,
  }) async {
    await _completionSub?.cancel();
    _bookId = bookId;
    _manifestId = manifest.manifestId;
    _manifest = manifest;
    _sessionId = null;
    _sessionActive = false;
    // Fold in the newest HLC of every stored event (own and remote), not
    // just this device's own: never lowers a clock already advanced by a
    // concurrent sync pull (observeHlc only moves forward).
    observeHlc(await journal.maxHlc());

    var initialIndex = manifest.files.indexWhere((f) => f.fileHash == initialPosition.fileHash);
    if (initialIndex == -1) initialIndex = 0; // needs_confirmation: start at chapter 1

    await _player.setAudioSources(
      sources,
      initialIndex: initialIndex,
      initialPosition: Duration(milliseconds: initialPosition.offsetMs),
    );
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
          author: author,
          artUri: artUri,
        ),
    ]);
    mediaItem.add(queue.value[initialIndex]);

    unawaited(_sync());
  }

  Position currentPosition() => _currentPosition();

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
    if (await _interceptMediaButton()) return;
    await playFrom(EventSource.system);
  }

  /// Like [play], but lets the caller pick the event `source`. The on-screen
  /// main button ([playPause]) calls this explicitly with `source: ui`
  /// rather than going through the ambiguous [play] override, which the
  /// platform also calls for hardware/system-originated play requests
  /// (headset button, lock-screen control, ...) with no way to tell those
  /// apart from here -- see the doc comment on [pauseFrom] for the same
  /// reasoning on the pause side.
  Future<void> playFrom(EventSource source) async {
    final position = _currentPosition();
    final event = _buildEvent(type: EventType.play, position: position, source: source);
    await _journal(event, () async => _startPlayback());
    _startHeartbeat();
    _startPeriodicSync();
  }

  /// Starts the main player without awaiting just_audio's `play()` future,
  /// which only completes once playback is paused or completed again --
  /// awaiting it would hold back everything after it (heartbeat, periodic
  /// sync, the undo hint, the Faden screen's result state) for the whole
  /// playback.
  void _startPlayback() => unawaited(_player.play());

  @override
  Future<void> pause() async {
    if (await _interceptMediaButton()) return;
    await pauseFrom(EventSource.system);
  }

  /// Like [pause], but lets the caller pick the event `source` -- a sleep
  /// timer expiry (signals/sleep_timer.dart) pauses with `source: timer`,
  /// which docs/ARCHITEKTUR.md section 5 / domain/event.dart deliberately
  /// does *not* count as an awake-proof, unlike a UI pause. The on-screen
  /// main button ([playPause]) calls this explicitly with `source: ui`; the
  /// bare [pause] override (the platform's own entry point -- headset
  /// button, lock-screen/notification control, an OS-level audio-focus
  /// interruption, ...) has no way to tell those origins apart, so it uses
  /// `source: system` uniformly (docs/ARCHITEKTUR.md section 9 explicitly
  /// anticipates this ambiguity for the AirPods sleep-detection case: "von
  /// einem bewussten Tastendruck nicht zu unterscheiden"). Either way,
  /// section 9's "Pause über Mediataste oder System im Nachtfenster" rule
  /// for `SLEEP_HINT` is evaluated here, right below.
  Future<void> pauseFrom(EventSource source) async {
    final position = _currentPosition();
    final event = _buildEvent(type: EventType.pause, position: position, source: source);
    await _journal(event, _player.pause);
    _sessionActive = false;
    _stopHeartbeat();
    _stopPeriodicSync();
    unawaited(_sync());
    if ((source == EventSource.mediaButton || source == EventSource.system) &&
        (isInNightWindow?.call() ?? false)) {
      await sleepHint(source: source);
    }
  }

  Future<void> playPause() => (_player.playing) ? pauseFrom(EventSource.ui) : playFrom(EventSource.ui);

  /// docs/ARCHITEKTUR.md section 9: hardware media buttons "Weiter" /
  /// "Zurück" are +/-30s, not a chapter skip.
  @override
  Future<void> skipToNext() async {
    if (await _interceptMediaButton()) return;
    await seekBySeconds(30, source: EventSource.mediaButton);
  }

  @override
  Future<void> skipToPrevious() async {
    if (await _interceptMediaButton()) return;
    await seekBySeconds(-30, source: EventSource.mediaButton);
  }

  @override
  Future<void> fastForward() async {
    if (await _interceptMediaButton()) return;
    await seekBySeconds(30, source: EventSource.mediaButton);
  }

  @override
  Future<void> rewind() async {
    if (await _interceptMediaButton()) return;
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
  void enterFadenMode() => _fadenModeActive = true;

  /// Ends Faden mode (search resolved, aborted, or the screen closed).
  void exitFadenMode() => _fadenModeActive = false;

  bool get fadenModeActive => _fadenModeActive;

  /// Emits once per media-button press received while [fadenModeActive] is
  /// true. ui/faden_screen.dart listens for this alongside a screen tap to
  /// resolve each probe's "kennst du das?" question.
  Stream<void> get fadenModeAnswers => _fadenAnswerController.stream;

  bool _consumeAsFadenAnswer() {
    if (!_fadenModeActive) return false;
    _fadenAnswerController.add(null);
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
  Future<bool> _interceptMediaButton() async {
    if (_consumeAsFadenAnswer()) return true;
    return _consumeAsLastMinuteExtend();
  }

  /// docs/ARCHITEKTUR.md section 5: writes an `AWAKE` event, throttled by
  /// [_awakeGate] to at most one per 10s combined across every trigger
  /// (screen touch, volume change, timer extension -- section 9). A no-op
  /// (returns false) while the cooldown hasn't elapsed yet.
  Future<bool> awake({EventSource source = EventSource.ui}) async {
    if (!_awakeGate.shouldEmit(clock.nowMs())) return false;
    final event = _buildEvent(type: EventType.awake, position: _currentPosition(), source: source);
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

  /// Sleep-timer expiry (signals/sleep_timer.dart's `onExpire`): the plain
  /// `PAUSE`/`source=timer` M4 already wrote via [pauseFrom], plus the
  /// `SLEEP_HINT` M5 adds (docs/ARCHITEKTUR.md section 9: "SLEEP_HINT
  /// entsteht beim Ablauf des Sleep-Timers" -- unconditional, unlike the
  /// night-window-gated media/system-pause case in [pauseFrom] above).
  Future<void> pauseForSleepTimerExpiry() async {
    await pauseFrom(EventSource.timer);
    await sleepHint(source: EventSource.timer);
  }

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
      _resumeTo(target, fileIndex: fileIndex, source: EventSource.faden);

  /// docs/KONZEPT.md "Faden aufnehmen": "Ab Stopp weiterhören" -- skips the
  /// search entirely and resumes exactly at the stop point (shown as a
  /// small line under the main button once `sleep_suspected` is true).
  Future<void> resumeFromStop(Position target, {required int? fileIndex}) =>
      _resumeTo(target, fileIndex: fileIndex, source: EventSource.ui);

  Future<void> _resumeTo(
    Position target, {
    required int? fileIndex,
    required EventSource source,
  }) async {
    // Invariant 6: a RESUME after falling asleep opens a new session, so the
    // Resolver's history (rule 6, winning session only) never records this
    // jump -- the undo hint is the one-tap way back to where playback stood.
    final manifest = _manifest;
    final from = _currentPosition();
    final fromGlobalMs = manifest?.globalMsFor(from);
    final toGlobalMs = manifest?.globalMsFor(target);
    final event = _buildEvent(type: EventType.resume, position: target, source: source);
    await _journal(event, () => _player.seek(Duration(milliseconds: target.offsetMs), index: fileIndex));
    if (manifest != null && fromGlobalMs != null && toGlobalMs != null) {
      final hint =
          undoHintForJump(from: from, fromGlobalMs: fromGlobalMs, toGlobalMs: toGlobalMs, manifest: manifest);
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
    if (manifest == null) return;
    final from = _currentPosition();
    final fromGlobalMs = manifest.globalMsFor(from);
    final clamped = globalMs.clamp(0, manifest.totalDurationMs);
    final target = manifest.positionForGlobalMs(clamped);
    final idx = manifest.files.indexWhere((f) => f.fileHash == target.fileHash);
    final event = _buildEvent(type: EventType.seek, position: target, source: source);
    await _journal(
      event,
      () => _player.seek(Duration(milliseconds: target.offsetMs), index: idx < 0 ? null : idx),
    );
    if (fromGlobalMs != null) {
      final hint =
          undoHintForJump(from: from, fromGlobalMs: fromGlobalMs, toGlobalMs: clamped, manifest: manifest);
      if (hint != null) _undoHintController.add(hint);
    }
  }

  /// "Rückgängig" (invariant 6) / a tap on a "Verlauf" (history) entry:
  /// jumps back to [target] as an `UNDO` event, per docs/ARCHITEKTUR.md
  /// section 5 ("UNDO | Rückgängig, 'Früher'").
  Future<void> undo(Position target) async {
    final manifest = _manifest;
    if (manifest == null) return;
    final idx = manifest.files.indexWhere((f) => f.fileHash == target.fileHash);
    final event = _buildEvent(type: EventType.undo, position: target, source: EventSource.ui);
    await _journal(
      event,
      () => _player.seek(Duration(milliseconds: target.offsetMs), index: idx < 0 ? null : idx),
    );
  }

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

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
    final event = _buildEvent(type: EventType.finished, position: position, source: EventSource.system);
    await _journal(event, () async {});
    unawaited(_sync());
  }

  Event _buildEvent({
    required EventType type,
    required Position position,
    required EventSource source,
    Map<String, dynamic> data = const {},
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
      sessionId: _sessionId!,
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
    _eventsWrittenController.add(null);
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

  Future<void> _sync() async {
    final client = syncClient;
    if (client == null) return;
    try {
      await client.sync();
    } catch (_) {
      // Offline: docs/KONZEPT.md Texte-Tabelle "Keine Verbindung zum
      // Server. Geladene Bücher spielen weiter." -- sync failures never
      // interrupt playback.
    }
  }

  void _wireBroadcast() {
    _playerSubs.add(_player.currentIndexStream.listen((idx) {
      _lastIndex = idx;
      _emitPosition();
      final manifest = _manifest;
      if (manifest != null && idx != null && idx >= 0 && idx < manifest.files.length) {
        final item = queue.value.length > idx ? queue.value[idx] : null;
        if (item != null) mediaItem.add(item);
      }
    }));
    _playerSubs.add(_player.positionStream.listen((pos) {
      _lastLocalPosition = pos;
      _emitPosition();
    }));
    _playerSubs.add(_player.playbackEventStream.listen(_broadcastState));
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
    if (syncClient?.onRemoteHlc == observeHlc) syncClient?.onRemoteHlc = null;
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
  }

  /// Whether audio is currently playing -- ui/player_screen.dart's main
  /// button icon.
  Stream<bool> get playingStream => _player.playingStream;
  bool get playing => _player.playing;

  /// Current playback speed -- ui/details_sheet.dart's Tempo control.
  Stream<double> get speedStream => _player.speedStream;
  double get speed => _player.speed;
}
