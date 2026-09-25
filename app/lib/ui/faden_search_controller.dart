import 'dart:async';

import '../domain/faden_search.dart' as fs;

/// One passage the search played (decision E64): where it lies (global
/// ms), its number, and the answer -- null while it is still being asked.
class FadenProbe {
  final int p;
  final int probeNr;
  final bool? known;

  const FadenProbe({required this.p, required this.probeNr, this.known});
}

/// One step of a running search, for the Faden-Modus screen (docs/KONZEPT.md
/// "Faden aufnehmen", E64): the shrinking thread ([lo]..[hi], the window
/// still searched), "Probe n von höchstens 8", the passage being asked
/// ([current]) and the ones already answered ([heard]). `probeNr` is 0
/// before the first probe starts.
class FadenProgress {
  final int lo;
  final int hi;
  final int probeNr;
  final int maxProbes;

  /// The passage being asked; null before the first probe and while an
  /// answer is being recorded.
  final FadenProbe? current;

  /// Every passage answered in this search, in order, each with its
  /// (recorded) answer.
  final List<FadenProbe> heard;

  /// Whether [current] plays or its answer window runs, so an answer
  /// counts now (false while the cue tone plays).
  final bool listening;

  /// Bumped every time an answer window (re)starts -- a new probe or
  /// [FadenSearchController.replay] -- so the screen restarts its
  /// probe + answer-window indicator.
  final int window;

  /// "Nochmal prüfen" (E91) asks [current] after the result.
  final bool rechecking;

  const FadenProgress({
    required this.lo,
    required this.hi,
    required this.probeNr,
    required this.maxProbes,
    this.current,
    this.heard = const [],
    this.listening = false,
    this.window = 0,
    this.rechecking = false,
  });
}

class FadenAbortedException implements Exception {
  const FadenAbortedException();
}

/// Orchestrates one Faden-Suche run (docs/ARCHITEKTUR.md section 8) against
/// real playback: plays the cue tone and each probe, waits for an answer
/// ("Kenne ich" / "Kenne ich nicht" on the screen or a media button, all
/// funnelled through [answer] by the caller) or lets the answer window
/// lapse, and reports every
/// PROBE/RESUME through the injected callbacks (docs/ARCHITEKTUR.md section
/// 8 closing note: "Jede Probe wird als PROBE-Event geschrieben, das
/// Ergebnis als RESUME-Event").
///
/// Deliberately Flutter-free (only `dart:async`) so the whole interaction
/// -- bisection, thread-shrink progress, the answer-window timing, abort,
/// and the "Früher" ladder -- can be driven with `fake_async` without
/// pumping a widget. The actual audio (audio/probe_player.dart) and
/// GestureDetector wiring lives in ui/faden_screen.dart.
class FadenSearchController {
  /// `last_awake`, global ms (docs/ARCHITEKTUR.md section 8: `lo`).
  final int lo;

  /// `stop`, global ms (section 8: `hi`).
  final int hi;

  /// Sentence-start offsets, global ms (domain/pause_index.dart).
  final List<int> pausen;

  /// Optional first guess from local health data (docs/ARCHITEKTUR.md
  /// section 9, M6) -- forwarded verbatim to [fs.fadenSuche]'s own `prior`
  /// parameter. Null (the default) reproduces exactly M5's behaviour: the
  /// ordinary "Fehlalarm-Test" runs as probe 1 instead.
  final int? prior;

  /// Whether [prior] was learned from earlier searches (decision E78):
  /// then probe 1, the "Fehlalarm-Test", still runs first and the prior
  /// only replaces the first midpoint. A health-data prior (false) replaces
  /// probe 1 itself, as before.
  final bool priorAfterFalseAlarm;

  /// The probe length setting (decision E77), 4, 6 or 8 s.
  final int probeLen;

  /// docs/KONZEPT.md: "Ein leiser Ton, dann eine Hörprobe" (6 s by
  /// default) -- played once before every probe.
  final Future<void> Function() playTone;

  /// Plays the probe at global-ms position [p]. Expected to resolve once
  /// playback has stopped on its own (probe length or file end,
  /// docs/ARCHITEKTUR.md section 8: "Eine Probe endet spätestens am
  /// Dateiende") -- this controller does not itself time the probe's own
  /// playback, only the total answer window below.
  final Future<void> Function(int p) playProbe;

  /// Force-stops any in-flight probe playback (used once an answer arrives,
  /// or on abort).
  final Future<void> Function() stopProbe;

  /// Records one `PROBE` event (docs/ARCHITEKTUR.md section 5: `data.known`).
  final Future<void> Function(int p, bool known) onProbeAnswered;

  /// Records one `RESUME` event and starts playback there -- called once
  /// with the search's own finding, and again for every subsequent
  /// "Früher" tap ([earlier]).
  final Future<void> Function(int startGlobalMs) onResumeAt;

  /// Told once the search stopped after [abort] ("Abbrechen", decision
  /// E89): nothing is resumed -- the position stays where it was and
  /// nothing starts playing.
  final Future<void> Function()? onAborted;

  /// Feedback after each recorded answer (decision E85): a click for
  /// "kenne ich", a soft tone for "kenne ich nicht" and for no answer.
  final Future<void> Function(bool known)? answerCue;

  /// Feedback right before the search's own result starts (E85).
  final Future<void> Function()? resultCue;

  /// "Nochmal prüfen" (E91) pauses what plays before asking again...
  final Future<void> Function()? onRecheckStarts;

  /// ...and, when the passage is still not recognised, lets it play on.
  final Future<void> Function()? onRecheckFailed;

  /// Decision E85: the answer window starts only once the probe actually
  /// plays ([probePlaying]) -- a streamed chapter can take seconds to load
  /// on a locked phone. False (tests): it starts with the probe call.
  final bool waitForProbeStart;

  /// The longest wait for [probePlaying] before the window runs anyway.
  static const Duration maxProbeStartWait = Duration(seconds: 10);

  /// Told after every start from the result (the search's own finding, a
  /// tapped passage, "Früher"), once playback runs there: where it started
  /// and whether that is a passage the listener recognised after the last
  /// awake proof -- not the fallback to `lo` and not a recognised probe 1
  /// (false alarm). ui/faden_screen.dart hands it to data/sleep_log.dart
  /// (decision E79). Never called for an abort.
  final Future<void> Function(int globalMs, bool recognised)? onChosen;

  final StreamController<FadenProgress> _progressController =
      StreamController<FadenProgress>.broadcast();

  late List<int> _leiter;
  int _leiterIndex = 0;

  /// Index of the search's own result in [_leiter]; -1 until it is known.
  int _resultIndex = -1;
  bool _aborted = false;
  bool _falseAlarm = false;

  /// The window still searched, for the thread (mirrors fs.fadenSuche:
  /// a "kenne ich" moves `lo` up to the probe, anything else `hi` down).
  late int _lo = lo;
  late int _hi = hi;
  int _probeNr = 0;
  FadenProbe? _current;
  final List<FadenProbe> _heard = [];
  bool _listening = false;
  int _window = 0;
  Timer? _windowTimer;

  /// Set by [dispose]: the screen is gone (back gesture / route pop without
  /// a result). Like [abort] this ends the search silently -- no further
  /// `PROBE`, no `RESUME`, no playback start -- but tells nobody.
  bool _disposed = false;
  Completer<bool>? _pendingAnswer;

  /// The answer window waiting for [probePlaying].
  void Function()? _startPendingWindow;

  /// Passages answered "kenne ich nicht" that "Nochmal prüfen" (E91) no
  /// longer offers (asked again and still not recognised).
  final Set<int> _recheckDeclined = {};
  bool _rechecking = false;

  FadenSearchController({
    required this.lo,
    required this.hi,
    required this.pausen,
    this.prior,
    this.priorAfterFalseAlarm = false,
    this.probeLen = fs.defaultProbeLen,
    required this.playTone,
    required this.playProbe,
    required this.stopProbe,
    required this.onProbeAnswered,
    required this.onResumeAt,
    this.onAborted,
    this.onChosen,
    this.answerCue,
    this.resultCue,
    this.onRecheckStarts,
    this.onRecheckFailed,
    this.waitForProbeStart = false,
  }) {
    _leiter = [lo];
  }

  Stream<FadenProgress> get progress => _progressController.stream;

  bool get canGoEarlier => _resultIndex >= 0 && _leiterIndex > 0;

  /// Whether the search has its result (and started playback there).
  bool get resolved => _resultIndex >= 0;

  /// The ladder (docs/ARCHITEKTUR.md section 8): the starting `lo`, then
  /// every recognised passage in order. Empty until [resolved].
  List<int> get leiter => resolved ? List.unmodifiable(_leiter) : const [];

  /// Where playback was last started, as an index into [leiter].
  int get leiterIndex => _leiterIndex;

  /// The search's own result, as an index into [leiter]; entries after it
  /// do not exist, entries before it are the earlier alternatives.
  int get resultIndex => _resultIndex;

  /// Whether the search's first probe (the false-alarm test) was
  /// recognised (E88).
  bool get falseAlarm => _falseAlarm;

  /// Runs the search to completion (or until [abort] fires). Never throws:
  /// an abort is reported through [onAborted], not as an exception out of
  /// this method.
  Future<void> start() async {
    _emitProgress(0);
    try {
      final result = await fs.fadenSuche(
        lo,
        hi,
        pausen,
        _frage,
        prior: prior,
        priorAfterFalseAlarm: priorAfterFalseAlarm,
        probeLen: probeLen,
      );
      if (_disposed) return;
      _leiter = result.leiter;
      _falseAlarm = result.falseAlarm;
      _leiterIndex = _resultIndex = _leiter.length - 1;
      await resultCue?.call();
      if (_disposed) return;
      await onResumeAt(result.start);
      await _chosen(result.start);
    } on FadenAbortedException {
      if (_disposed) return;
      await onAborted?.call();
    }
  }

  void _emitProgress(int probeNr) {
    _probeNr = probeNr;
    _emit();
  }

  void _emit() {
    if (_disposed || _progressController.isClosed) return;
    _progressController.add(FadenProgress(
      lo: _lo,
      hi: _hi,
      probeNr: _probeNr,
      maxProbes: fs.maxProbes,
      current: _current,
      heard: List.unmodifiable(_heard),
      listening: _listening,
      window: _window,
      rechecking: _rechecking,
    ));
  }

  Future<bool> _frage(int p, int probeNr) async {
    if (_aborted) throw const FadenAbortedException();
    _current = FadenProbe(p: p, probeNr: probeNr);
    _listening = false;
    _emitProgress(probeNr);
    await playTone();
    if (_aborted) throw const FadenAbortedException();

    final completer = Completer<bool>();
    _pendingAnswer = completer;
    _startWindow(p, completer);
    bool known;
    try {
      known = await completer.future;
    } finally {
      _windowTimer?.cancel();
      _windowTimer = null;
      _startPendingWindow = null;
      _pendingAnswer = null;
    }

    if (_aborted) throw const FadenAbortedException();
    _listening = false;
    _emit();
    // An early answer ends the passage (the window's own end has stopped
    // it already).
    await stopProbe();
    if (_aborted) throw const FadenAbortedException();
    // Journal first (invariant 3), then show the answer as given.
    await onProbeAnswered(p, known);
    _heard.add(FadenProbe(p: p, probeNr: probeNr, known: known));
    // Heard, not only seen (E85); the next tone follows it.
    if (!_disposed) await answerCue?.call(known);
    if (known) {
      _lo = p;
    } else {
      _hi = p;
    }
    _current = null;
    _emit();
    return known;
  }

  /// Plays the probe at [p] and (re)starts its answer window: probe_len +
  /// answer_window, after which silence counts as "kenne ich nicht".
  void _startWindow(int p, Completer<bool> completer) {
    _windowTimer?.cancel();
    void run() {
      _startPendingWindow = null;
      _windowTimer?.cancel();
      _windowTimer = Timer(Duration(milliseconds: probeLen + fs.answerWindow), () {
        if (!completer.isCompleted) completer.complete(false);
      });
      _window++;
      _emit();
    }

    _listening = true;
    if (waitForProbeStart) {
      _startPendingWindow = run;
      // Never waits forever: a probe that fails to load still gets its
      // window (and then counts as "kenne ich nicht").
      _windowTimer = Timer(maxProbeStartWait, run);
      _emit();
      unawaited(playProbe(p).catchError((Object _) {}));
    } else {
      unawaited(playProbe(p).catchError((Object _) {}));
      run();
    }
  }

  /// The probe being asked started to play (E85): its answer window runs
  /// from now on. Ignored when no window waits for it.
  void probePlaying() {
    final pending = _startPendingWindow;
    if (pending != null && !_disposed) pending();
  }

  /// The answer to the passage being asked (E64): "Kenne ich" ([known]
  /// true, also every media-button press) or "Kenne ich nicht", which
  /// counts at once instead of waiting for the window to lapse. Only the
  /// first answer to a passage counts; outside an answer window (cue tone,
  /// between probes, after the result) it is ignored.
  void answer({required bool known}) {
    final pending = _pendingAnswer;
    if (pending != null && !pending.isCompleted) pending.complete(known);
  }

  /// "Kenne ich": a media-button press, or the screen's button.
  void submitAnswer() => answer(known: true);

  /// "Nochmal hören" (E64): plays the passage being asked again and
  /// restarts its answer window. Still one answer, one PROBE.
  void replay() {
    final pending = _pendingAnswer;
    final current = _current;
    if (_aborted || pending == null || pending.isCompleted || current == null) return;
    _startWindow(current.p, pending);
  }

  /// "Abbrechen" (E89). Safe to call at any point during [start] (including
  /// before the first probe, or between two probes while the cue tone is
  /// playing) -- the running search stops at its next checkpoint, and
  /// [onAborted] is told; nothing is resumed.
  void abort() {
    if (_aborted) return;
    _aborted = true;
    // Also reached from [dispose], which set `_disposed` first so that
    // [start] then skips [onAborted].
    unawaited(stopProbe());
    final pending = _pendingAnswer;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(const FadenAbortedException());
    }
  }

  /// "Früher" (docs/KONZEPT.md Texte-Tabelle: "Leiter | Früher"): one step
  /// back through the ladder from where playback was last started, then
  /// resumes there (another `RESUME`/`source=faden`, per docs/ARCHITEKTUR.md
  /// section 8's closing note -- every ladder step is its own RESUME).
  Future<void> earlier() async {
    if (_disposed || !canGoEarlier) return;
    _leiterIndex = fs.stepEarlier(_leiterIndex);
    final pos = fs.positionAtLeiterIndex(_leiter, _leiterIndex);
    await onResumeAt(pos);
    await _chosen(pos);
  }

  Future<void> _chosen(int globalMs) async {
    final chosen = onChosen;
    if (chosen == null || _disposed) return;
    await chosen(globalMs, _leiterIndex > 0 && !_falseAlarm);
  }

  /// A recognised passage tapped on the result screen (E64): resumes at
  /// [leiter] entry [index] (its own RESUME/`source=faden`). Never later
  /// than the search's result (invariant 9: nothing past what the listener
  /// recognised is skipped), so any index above [resultIndex] is ignored.
  Future<void> resumeAtLeiterIndex(int index) async {
    if (_disposed || !resolved || index < 0 || index > _resultIndex) return;
    _leiterIndex = index;
    final pos = fs.positionAtLeiterIndex(_leiter, index);
    await onResumeAt(pos);
    await _chosen(pos);
  }

  /// "Nochmal prüfen" (decision E91): after the result, the earliest
  /// passage answered "kenne ich nicht" -- the nearest one after where
  /// playback started -- or null. Asking it again can only move the result
  /// forward by a new "kenne ich" (invariant 9).
  int? get recheckCandidate {
    if (!resolved || _disposed || _rechecking) return null;
    final from = _leiter[_resultIndex];
    int? best;
    for (final probe in _heard) {
      if (probe.known != false || probe.p <= from || _recheckDeclined.contains(probe.p)) continue;
      if (best == null || probe.p < best) best = probe.p;
    }
    return best;
  }

  /// Asks [recheckCandidate] once more (tone, probe, answer window, one
  /// `PROBE`). Recognised now: it becomes the new result, played from
  /// there (a `RESUME` of its own) and the ladder's newest step. Still not:
  /// playback goes on where it was and the passage is not offered again.
  Future<void> recheck() async {
    final u = recheckCandidate;
    if (u == null) return;
    _rechecking = true;
    _aborted = false;
    _emit();
    try {
      await onRecheckStarts?.call();
      if (_disposed) return;
      final known = await _frage(u, _probeNr);
      if (_disposed) return;
      if (known) {
        _leiter = [..._leiter.take(_resultIndex + 1), u];
        _leiterIndex = _resultIndex = _leiter.length - 1;
        _rechecking = false;
        _emit();
        await resultCue?.call();
        if (_disposed) return;
        await onResumeAt(u);
        await _chosen(u);
      } else {
        _recheckDeclined.add(u);
        _rechecking = false;
        _emit();
        await onRecheckFailed?.call();
      }
    } on FadenAbortedException {
      // Left during the question: nothing more to do.
    } finally {
      _rechecking = false;
    }
  }

  /// Ends the search for good (the screen was left, with or without a
  /// result): stops any in-flight probe and makes the running [start]
  /// return at its next checkpoint without writing another `PROBE`, without
  /// a `RESUME` and without starting playback. An answer that has not been
  /// recorded yet is dropped, so `lo` never moves (invariant 9).
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _windowTimer?.cancel();
    abort();
    unawaited(_progressController.close());
  }
}
