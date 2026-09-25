import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' as ja;

import '../audio/handler.dart';
import '../audio/probe_player.dart';
import '../domain/asleep_prompt.dart';
import '../domain/event.dart';
import '../domain/faden_gestures.dart';
import '../domain/faden_offer.dart';
import '../domain/faden_search.dart' as fs;
import '../domain/manifest.dart';
import '../domain/pause_index.dart';
import '../domain/sleep_onset.dart';
import '../l10n/strings.dart';
import '../signals/night.dart';
import 'faden_search_controller.dart';
import 'format.dart';
import 'providers.dart';

/// One Faden search as it runs (decisions E85-E91), with or without its
/// screen: the probe player, the search controller, the headphone buttons
/// and the sounds. ui/faden_screen.dart only shows it; a play from the lock
/// screen can run it with the phone locked (the audit's finding 1), and
/// the screen appears once the app is in front (ui/faden_session_host.dart).
///
/// - Buttons (E85, domain/faden_gestures.dart): 1x "Kenne ich", 2x "Kenne
///   ich nicht", 3x "Nochmal hören"; on the result 3x "Etwas früher
///   anfangen", everything else acts normally again.
/// - Sounds (E85): a click after "kenne ich", a soft tone after "kenne ich
///   nicht" or no answer, a double tone before the result; near-silence in
///   between keeps a locked iPhone's app alive; the answer window starts
///   once the probe actually plays.
/// - "Abbrechen" ([cancel], E89) leaves position and playback as they
///   were; "Fertig" ([close]) ends the result.
class FadenSession extends ChangeNotifier {
  final FadenAudioHandler handler;
  final Manifest manifest;

  /// `last_awake`, global ms.
  final int lo;

  /// `stop`, global ms (or earlier, from a local sleep-onset reading).
  final int hi;

  /// The stop point itself, global ms ("4 Min. bevor es anhielt").
  final int stop;

  final int probeLen;

  /// The local clock time a passage was heard at ("23:12"), from the
  /// sleeping session's heartbeats; null when unknown.
  final String? Function(int globalMs)? heardAt;

  final ProbePlayer _probe;
  late final FadenSearchController controller;
  StreamSubscription<RemoteCommand>? _buttons;
  StreamSubscription<FadenProgress>? _progressSub;

  /// The latest progress of the search.
  FadenProgress? progress;

  /// The search has its result and playback runs.
  bool found = false;

  /// Where playback was last started from the result (global ms).
  int? playingMs;

  /// Ended by [cancel] or [close]; nothing more happens.
  bool ended = false;

  /// Told once when the session ends (the holder forgets it).
  VoidCallback? onEnded;

  /// A RESUME is being written: further taps wait.
  bool _busy = false;

  int _screens = 0;
  Timer? _idleClose;

  /// Without a screen, the result stays reachable by the buttons this long.
  static const Duration resultWithoutScreen = Duration(minutes: 2);

  FadenSession({
    required this.handler,
    required this.manifest,
    required this.lo,
    required this.hi,
    int? stop,
    required List<int> pausen,
    required List<ja.IndexedAudioSource> playlistSources,
    int? prior,
    bool priorAfterFalseAlarm = false,
    this.probeLen = fs.defaultProbeLen,
    Future<void> Function(int globalMs, bool recognised)? onChosen,
    this.heardAt,
    ProbePlayer? probePlayer,
    bool waitForProbeStart = true,
  })  : stop = stop ?? hi,
        _probe = probePlayer ?? ProbePlayer() {
    _probe.open(playlistSources);
    controller = FadenSearchController(
      lo: lo,
      hi: hi,
      pausen: pausen,
      prior: prior,
      priorAfterFalseAlarm: priorAfterFalseAlarm,
      probeLen: probeLen,
      playTone: _probe.playTone,
      playProbe: _playProbe,
      stopProbe: _probe.stop,
      onProbeAnswered: (p, known) => handler.probe(position: manifest.positionForGlobalMs(p), known: known),
      onResumeAt: _resolved,
      onChosen: onChosen,
      answerCue: (known) => _probe.playCue(known ? FadenCue.known : FadenCue.unknown),
      resultCue: () => _probe.playCue(FadenCue.result),
      onRecheckStarts: _recheckStarts,
      onRecheckFailed: _recheckFailed,
      waitForProbeStart: waitForProbeStart,
    );
  }

  Future<void> _playProbe(int p) {
    final pos = manifest.positionForGlobalMs(p);
    final idx = manifest.indexOf(pos.fileHash);
    if (idx < 0) {
      controller.probePlaying();
      return Future.value();
    }
    return _probe.playProbe(
      fileIndex: idx,
      offsetMs: pos.offsetMs,
      probeLenMs: probeLen,
      fileDurationMs: manifest.files[idx].durationMs,
      onPlaying: controller.probePlaying,
    );
  }

  /// Starts the search: the buttons answer from now on.
  void start() {
    handler.enterFadenMode();
    _buttons = handler.fadenModeAnswers.listen(_onButton);
    _progressSub = controller.progress.listen((p) {
      progress = p;
      _notify();
    });
    unawaited(() async {
      // Near-silence first, so the tone that follows is never undercut.
      await _probe.setKeepAlive(true);
      if (!ended) await controller.start();
    }());
  }

  void _onButton(RemoteCommand command) {
    final phase = handler.fadenModeActive ? FadenRemotePhase.search : FadenRemotePhase.result;
    switch (fadenGestureFor(command, phase, canGoEarlier: controller.canGoEarlier)) {
      case FadenGesture.known:
        controller.answer(known: true);
      case FadenGesture.unknown:
        controller.answer(known: false);
      case FadenGesture.replay:
        controller.replay();
      case FadenGesture.earlier:
        unawaited(earlier());
      case null:
        break;
    }
  }

  /// Whether a probe is being asked (the search, or "Nochmal prüfen").
  bool get asking => !found || (progress?.rechecking ?? false);

  /// The passage "Nochmal prüfen" offers (E91), or null.
  int? get recheckMs => ended ? null : controller.recheckCandidate;

  /// What the result says (E88).
  fs.FadenResultKind get resultKind => fs.fadenResultKind(
        falseAlarm: controller.falseAlarm,
        leiterIndex: controller.leiterIndex,
        resultIndex: controller.resultIndex,
      );

  /// "gehört gegen 23:12 Uhr" (E89), or "Kapitel 5 · 23:14" when the time
  /// is unknown.
  String passageLabel(int globalMs) {
    final time = heardAt?.call(globalMs);
    if (time != null) return AppStrings.fadenHeardAt(time);
    final pos = manifest.positionForGlobalMs(globalMs);
    final idx = manifest.indexOf(pos.fileHash);
    return AppStrings.fadenPassage(AppStrings.chapterLabel(idx + 1), formatClock(pos.offsetMs));
  }

  /// "4 Min. bevor es anhielt".
  String beforeStopLabel(int globalMs) => AppStrings.fadenBeforeStop(formatBeforeStop(stop - globalMs));

  void answer({required bool known}) {
    if (!asking) return;
    controller.answer(known: known);
  }

  void replay() => controller.replay();

  Future<void> earlier() => _guard(controller.earlier);

  Future<void> resumeAtLeiterIndex(int index) => _guard(() => controller.resumeAtLeiterIndex(index));

  /// "Nochmal prüfen" (E91).
  Future<void> recheck() => _guard(controller.recheck);

  Future<void> _guard(Future<void> Function() action) async {
    if (_busy || ended) return;
    _busy = true;
    try {
      await action();
    } finally {
      _busy = false;
    }
  }

  /// The search's own finding, a tapped passage, a "Früher" step or a
  /// recheck: playback starts there and the result shows.
  Future<void> _resolved(int globalMs) async {
    if (ended) return;
    await _probe.setKeepAlive(false);
    final pos = manifest.positionForGlobalMs(globalMs);
    final idx = manifest.indexOf(pos.fileHash);
    await handler.resumeFromFaden(pos, fileIndex: idx < 0 ? null : idx);
    // Playback runs again: the buttons, the AirPods' sleep detection and
    // the sleep timer work normally, except 3x for "Etwas früher".
    handler.enterFadenResultMode(canGoEarlier: () => controller.canGoEarlier);
    found = true;
    playingMs = globalMs;
    _notify();
    _armIdleClose();
  }

  Future<void> _recheckStarts() async {
    _idleClose?.cancel();
    handler.enterFadenMode();
    await _probe.setKeepAlive(true);
    if (handler.playing) await handler.pauseFrom(EventSource.faden);
  }

  Future<void> _recheckFailed() async {
    await _probe.setKeepAlive(false);
    handler.enterFadenResultMode(canGoEarlier: () => controller.canGoEarlier);
    await handler.playFrom(EventSource.faden);
    _armIdleClose();
  }

  /// The screen shows this session (or stopped showing it).
  void attachScreen() {
    _screens++;
    _idleClose?.cancel();
  }

  void detachScreen() {
    if (_screens > 0) _screens--;
    _armIdleClose();
  }

  bool get screenAttached => _screens > 0;

  void _armIdleClose() {
    _idleClose?.cancel();
    if (!found || screenAttached || ended) return;
    _idleClose = Timer(resultWithoutScreen, close);
  }

  /// "Abbrechen" or leaving the screen before the result (E89): the search
  /// stops, the position stays and nothing starts playing. Answers already
  /// given stay journaled as PROBE events; `lo` moved by none of them.
  Future<void> cancel() => _end();

  /// "Fertig", or leaving the result: playback goes on as it is.
  Future<void> close() => _end();

  Future<void> _end() async {
    if (ended) return;
    // Left during "Nochmal prüfen": the result played before, so it plays
    // on where it was paused for the question.
    final resumeResult = found && (progress?.rechecking ?? false);
    ended = true;
    _idleClose?.cancel();
    handler.exitFadenMode();
    controller.dispose();
    unawaited(_buttons?.cancel());
    unawaited(_progressSub?.cancel());
    onEnded?.call();
    _notify();
    if (resumeResult) unawaited(handler.playFrom(EventSource.faden));
    try {
      await _probe.setKeepAlive(false);
      await _probe.stop();
    } finally {
      await _probe.dispose();
    }
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  bool _disposed = false;

  @override
  void dispose() {
    unawaited(_end());
    _disposed = true;
    super.dispose();
  }
}

/// The Faden search running now, if any (one at a time).
class FadenSessionHolder extends Notifier<FadenSession?> {
  @override
  FadenSession? build() => null;

  /// Runs [session], ending one that still runs.
  void run(FadenSession session) {
    final previous = state;
    if (previous != null && !identical(previous, session)) unawaited(previous.cancel());
    session.onEnded = () {
      if (identical(state, session)) state = null;
    };
    state = session;
    session.start();
  }
}

final fadenSessionProvider = NotifierProvider<FadenSessionHolder, FadenSession?>(FadenSessionHolder.new);

/// Starts Faden searches for the open book (decisions E84, E86):
/// [fromBookState] with the Resolver's `last_awake`/`stop` (the player's
/// buttons, a play from outside), [fromStretch] with the listening since
/// the last awake proof ("Eingeschlafen?"). Learns only from nights
/// ([learnsFromSession], E90).
class FadenStarter {
  final Ref _ref;

  FadenStarter(this._ref);

  /// Test seam: the probe player new sessions use (null: a real one).
  @protected
  ProbePlayer? get probePlayerForTests => null;

  /// The Resolver's window (docs/KONZEPT.md "Faden aufnehmen"), with the
  /// health-data adjustment (section 9) and the learned prior (E78).
  Future<FadenSession?> fromBookState() async {
    final session = _ref.read(playerSessionProvider);
    final manifest = session.manifest;
    final bookState = session.bookState;
    if (manifest == null || bookState == null) return null;
    final lo = manifest.globalMsFor(bookState.lastAwake);
    var hi = manifest.globalMsFor(bookState.stop);
    if (lo == null || hi == null || hi <= lo) return null;
    final stopMs = hi;
    int? prior;
    // docs/ARCHITEKTUR.md section 9 / M6: `hi` and a first guess from a
    // local sleep-onset reading, if wanted; `lo` is never touched here
    // (invariant 9).
    final optedIn = await _ref.read(settingsStoreProvider).healthDataOptIn();
    final adjustment = await session.sleepOnsetAdjustment(
      dataSource: _ref.read(sleepDataSourceProvider),
      optedIn: optedIn,
      lo: lo,
      hi: hi,
    );
    if (adjustment != null) {
      hi = adjustment.hi;
      prior = adjustment.prior;
    }
    return _start(
      lo: lo,
      hi: hi,
      stop: stopMs,
      prior: prior,
      sleepingSession: bookState.sessionId,
      learn: learnsFromSession(inNightWindow: bookState.inNightWindow, stopReason: bookState.stopReason),
    );
  }

  /// "Ja, Stelle suchen" (E84), or a play from outside when only the
  /// question would have asked: from the last awake proof to where it
  /// plays or stopped now.
  Future<FadenSession?> fromStretch(ListeningStretch stretch) async {
    final handler = _ref.read(audioHandlerProvider);
    final session = _ref.read(playerSessionProvider);
    final manifest = session.manifest;
    final lo = stretch.lastAwakeGlobalMs;
    if (manifest == null || lo == null || handler.bookId != session.bookId) return null;
    final hi = manifest.globalMsFor(handler.currentPosition());
    if (hi == null || hi <= lo) return null;
    final window = await _nightWindow();
    final at = stretch.lastListenWallMs ?? handler.clock.nowMs();
    final night = isInNightWindow(
      nowWallMs: at,
      tzMin: handler.clock.tzOffsetMin(),
      nightStartMin: window.startMin,
      nightEndMin: window.endMin,
    );
    return _start(
      lo: lo,
      hi: hi,
      stop: hi,
      sleepingSession: handler.sessionId,
      learn: learnsFromSession(inNightWindow: night, stopReason: stretch.stopReason),
    );
  }

  Future<NightWindow> _nightWindow() async {
    try {
      return await _ref.read(nightWindowProvider.future);
    } catch (_) {
      return NightWindow.defaults;
    }
  }

  Future<FadenSession?> _start({
    required int lo,
    required int hi,
    required int stop,
    int? prior,
    required String? sleepingSession,
    required bool learn,
  }) async {
    final session = _ref.read(playerSessionProvider);
    final manifest = session.manifest;
    final sources = session.playlistSources;
    final bookId = session.bookId;
    if (manifest == null || sources == null || bookId == null) return null;
    if (_ref.read(fadenSessionProvider) != null) return null;
    final handler = _ref.read(audioHandlerProvider);
    final pausen = globalPauseOffsets(manifest, session.pauseIndex);

    // E78: without a health-data prior, the first bisection point comes
    // from earlier searches; probe 1 still runs first.
    final sleepLog = _ref.read(sleepLogProvider);
    var learned = false;
    if (prior == null) {
      prior = await sleepLog.learnedPriorFor(lo: lo, hi: hi);
      learned = prior != null;
    }
    final probeLen = await _ref.read(probeLengthProvider.future);
    final heardAt = await _heardAtFor(bookId, sleepingSession, manifest);
    if (_ref.read(fadenSessionProvider) != null) return null;

    final faden = FadenSession(
      handler: handler,
      manifest: manifest,
      lo: lo,
      hi: hi,
      stop: stop,
      pausen: pausen,
      playlistSources: sources,
      prior: prior,
      priorAfterFalseAlarm: learned,
      probeLen: probeLen,
      heardAt: heardAt,
      probePlayer: probePlayerForTests,
      // E79, E90: every start from the result is remembered locally as
      // this night's sleep onset (and, if wanted, goes to Health, E82) --
      // only for a night, never an event.
      onChosen: learn && sleepingSession != null
          ? (globalMs, recognised) => sleepLog.recordChoice(
                bookId: bookId,
                sessionId: sleepingSession,
                manifest: manifest,
                loGlobalMs: lo,
                chosenGlobalMs: globalMs,
                recognised: recognised,
              )
          : null,
    );
    _ref.read(fadenSessionProvider.notifier).run(faden);
    return faden;
  }

  /// "gehört gegen 23:12 Uhr" (E89): positions of the sleeping session
  /// mapped to its wall clock through its heartbeats (domain/sleep_onset.dart
  /// `wallClockAtPosition`); null when there are none.
  Future<String? Function(int)?> _heardAtFor(String bookId, String? sessionId, Manifest manifest) async {
    if (sessionId == null) return null;
    try {
      final events = await _ref.read(journalProvider).eventsForBook(bookId);
      final heartbeats = <HeartbeatSample>[];
      var tzMin = 0;
      for (final e in events) {
        if (e.sessionId != sessionId) continue;
        tzMin = e.tzMin;
        if (e.type != EventType.heartbeat) continue;
        final g = manifest.globalMsFor(e.position);
        if (g != null) heartbeats.add(HeartbeatSample(wallMs: e.wallMs, globalMs: g));
      }
      if (heartbeats.isEmpty) return null;
      return (globalMs) {
        final wall = wallClockAtPosition(heartbeats, globalMs);
        return wall == null ? null : formatClockOfDay(wall, tzMin);
      };
    } catch (_) {
      return null;
    }
  }
}

final fadenStarterProvider = Provider<FadenStarter>(FadenStarter.new);

/// "Eingeschlafen?" (decision E84): whether the question is due now, and
/// which stretch it was asked for (once per stretch).
class AsleepGuard {
  final Ref _ref;

  AsleepGuard(this._ref);

  /// The stretch the question was last shown for.
  int? askedStretchId;

  AsleepAsk due() {
    final handler = _ref.read(audioHandlerProvider);
    if (handler.bookId == null) return AsleepAsk.no;
    final stretch = handler.stretch;
    final window = _ref.read(nightWindowProvider).value ?? NightWindow.defaults;
    final night = isInNightWindow(
      nowWallMs: stretch.lastListenWallMs ?? handler.clock.nowMs(),
      tzMin: handler.clock.tzOffsetMin(),
      nightStartMin: window.startMin,
      nightEndMin: window.endMin,
    );
    return asleepPromptDue(
      stretch: stretch,
      inNightWindow: night,
      carRoute: handler.carRoute,
      askedStretchId: askedStretchId,
      fadenActive: _ref.read(fadenSessionProvider) != null || handler.fadenSearchRunning,
    );
  }
}

final asleepGuardProvider = Provider<AsleepGuard>(AsleepGuard.new);

/// A play from the lock screen, Control Center or the headphones while
/// sleep is suspected starts the Faden search (decision E86, the audit's
/// finding 1) -- where the search is the main button (night, sleep timer)
/// or "Eingeschlafen?" would ask; never in the car. The false alarm stays
/// one press away: probe 1 plays 25 s before the stop, and a second press
/// is "Kenne ich" there. Watched by the app root (main.dart).
final fadenRemotePlayWiringProvider = Provider<void>((ref) {
  final handler = ref.watch(audioHandlerProvider);
  Future<bool> onRemotePlay() async {
    if (ref.read(fadenSessionProvider) != null) return false;
    final session = ref.read(playerSessionProvider);
    final state = session.bookState;
    if (state == null || session.bookId != handler.bookId || state.needsConfirmation) return false;
    final guard = ref.read(asleepGuardProvider);
    final ask = guard.due();
    final offer = fadenOfferFor(state);
    if (!searchesOnRemotePlay(offer: offer, asleepAsk: ask, carRoute: handler.carRoute)) return false;
    final starter = ref.read(fadenStarterProvider);
    final stretch = handler.stretch;
    guard.askedStretchId = stretch.id;
    final started = offer == FadenOffer.primary ? await starter.fromBookState() : await starter.fromStretch(stretch);
    return started != null;
  }

  handler.onRemotePlay = onRemotePlay;
  ref.onDispose(() {
    if (handler.onRemotePlay == onRemotePlay) handler.onRemotePlay = null;
  });
});
