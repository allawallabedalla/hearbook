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
import 'undo_hint.dart';

/// The audio_service integration (docs/ARCHITEKTUR.md section 11:
/// "handler.dart (audio_service)"): background playback, lock-screen
/// controls and media-button handling, built around a just_audio
/// [ja.AudioPlayer]. This is also where every user-intent transport action
/// (PLAY, SEEK via +/-30s, UNDO) is turned into a journal event *before*
/// the actual player action runs (invariant 3), and where the app's own
/// heartbeat (every 5s while playing, invariant 3) and sync triggers
/// (section 6: start, pause, every 60s while playing) live.
///
/// Scope note (M4): media-button next/previous map to +/-30s, not to a
/// real "next chapter" skip -- docs/ARCHITEKTUR.md section 9: "Mediatasten:
/// normal Play/Pause, Weiter = +30 s, Zurück = -30 s." Faden-Suche
/// (docs/ARCHITEKTUR.md section 8) and AWAKE/SLEEP_HINT events (section 9)
/// are M5 scope and not produced here.
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

  int? _lastIndex;
  Duration _lastLocalPosition = Duration.zero;
  final StreamController<Position> _positionController =
      StreamController<Position>.broadcast();
  final StreamController<UndoHint> _undoHintController = StreamController<UndoHint>.broadcast();
  final StreamController<void> _eventsWrittenController = StreamController<void>.broadcast();

  FadenAudioHandler({required this.journal, required this.deviceId, this.syncClient, this.clock = const SystemClock()}) {
    _wireBroadcast();
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
  }) async {
    await _completionSub?.cancel();
    _bookId = bookId;
    _manifestId = manifest.manifestId;
    _manifest = manifest;
    _sessionId = null;
    _sessionActive = false;
    _hlc = await journal.latestHlc(deviceId);

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
        MediaItem(
          id: file.fileHash,
          title: AppStrings.chapterLabel(file.idx + 1),
          album: bookTitle,
          duration: Duration(milliseconds: file.durationMs),
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
    final position = _currentPosition();
    final event = _buildEvent(type: EventType.play, position: position, source: EventSource.ui);
    await _journal(event, _player.play);
    _startHeartbeat();
    _startPeriodicSync();
  }

  @override
  Future<void> pause() => pauseFrom(EventSource.ui);

  /// Like [pause], but lets the caller pick the event `source` -- a sleep
  /// timer expiry (signals/sleep_timer.dart) pauses with `source: timer`,
  /// which docs/ARCHITEKTUR.md section 5 / domain/event.dart deliberately
  /// does *not* count as an awake-proof, unlike a UI pause.
  Future<void> pauseFrom(EventSource source) async {
    final position = _currentPosition();
    final event = _buildEvent(type: EventType.pause, position: position, source: source);
    await _journal(event, _player.pause);
    _sessionActive = false;
    _stopHeartbeat();
    _stopPeriodicSync();
    unawaited(_sync());
  }

  Future<void> playPause() => (_player.playing) ? pause() : play();

  /// docs/ARCHITEKTUR.md section 9: hardware media buttons "Weiter" /
  /// "Zurück" are +/-30s, not a chapter skip.
  @override
  Future<void> skipToNext() => seekBySeconds(30, source: EventSource.mediaButton);

  @override
  Future<void> skipToPrevious() => seekBySeconds(-30, source: EventSource.mediaButton);

  @override
  Future<void> fastForward() => seekBySeconds(30, source: EventSource.mediaButton);

  @override
  Future<void> rewind() => seekBySeconds(-30, source: EventSource.mediaButton);

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
    _player.currentIndexStream.listen((idx) {
      _lastIndex = idx;
      _emitPosition();
      final manifest = _manifest;
      if (manifest != null && idx != null && idx >= 0 && idx < manifest.files.length) {
        final item = queue.value.length > idx ? queue.value[idx] : null;
        if (item != null) mediaItem.add(item);
      }
    });
    _player.positionStream.listen((pos) {
      _lastLocalPosition = pos;
      _emitPosition();
    });
    _player.playbackEventStream.listen(_broadcastState);
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
    await _completionSub?.cancel();
    await _positionController.close();
    await _undoHintController.close();
    await _eventsWrittenController.close();
    await _player.dispose();
  }

  /// Whether audio is currently playing -- ui/player_screen.dart's main
  /// button icon.
  Stream<bool> get playingStream => _player.playingStream;
  bool get playing => _player.playing;

  /// Current playback speed -- ui/details_sheet.dart's Tempo control.
  Stream<double> get speedStream => _player.speedStream;
  double get speed => _player.speed;
}
