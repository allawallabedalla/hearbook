import 'dart:async';

import '../domain/faden_search.dart' as fs;

/// One step of a running search, for the Faden-Modus screen's shrinking
/// thread + "Probe n von höchstens 8" counter (docs/KONZEPT.md
/// "Faden aufnehmen"). `probeNr` is 0 before the first probe starts.
class FadenProgress {
  final int lo;
  final int hi;
  final int probeNr;
  final int maxProbes;

  const FadenProgress({
    required this.lo,
    required this.hi,
    required this.probeNr,
    required this.maxProbes,
  });
}

class FadenAbortedException implements Exception {
  const FadenAbortedException();
}

/// Orchestrates one Faden-Suche run (docs/ARCHITEKTUR.md section 8) against
/// real playback: plays the cue tone and each probe, waits for an answer
/// (a screen tap or a media button -- both funnelled through [submitAnswer]
/// by the caller) or lets the answer window lapse, and reports every
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

  /// docs/KONZEPT.md: "Ein leiser Ton, dann eine 4 s lange Hörprobe" --
  /// played once before every probe.
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

  /// Long-press abort (docs/KONZEPT.md: "Langer Druck auf den Screen bricht
  /// ab und startet am letzten sicheren Wach-Punkt."). Called with [lo]
  /// itself, unmodified by [fs.preroll] -- "der letzte sichere Wach-Punkt"
  /// is a specific, already-known position, unlike the search's own
  /// never-answered fallback ([fs.fadenSuche]'s `start` when nothing was
  /// ever confirmed, which *does* subtract the preroll).
  final Future<void> Function(int lastAwakeGlobalMs) onAborted;

  final StreamController<FadenProgress> _progressController =
      StreamController<FadenProgress>.broadcast();

  late List<int> _leiter;
  int _leiterIndex = 0;
  bool _aborted = false;

  /// Set by [dispose]: the screen is gone (back gesture / route pop without
  /// a result). Unlike a long-press [abort], this must end the search
  /// silently -- no further `PROBE`, no `RESUME` via [onAborted] or
  /// [onResumeAt], no playback start.
  bool _disposed = false;
  Completer<bool>? _pendingAnswer;

  FadenSearchController({
    required this.lo,
    required this.hi,
    required this.pausen,
    this.prior,
    required this.playTone,
    required this.playProbe,
    required this.stopProbe,
    required this.onProbeAnswered,
    required this.onResumeAt,
    required this.onAborted,
  }) {
    _leiter = [lo];
  }

  Stream<FadenProgress> get progress => _progressController.stream;

  bool get canGoEarlier => _leiterIndex > 0;

  /// Runs the search to completion (or until [abort] fires). Never throws:
  /// an abort is reported through [onAborted], not as an exception out of
  /// this method.
  Future<void> start() async {
    _emitProgress(0);
    try {
      final result = await fs.fadenSuche(lo, hi, pausen, _frage, prior: prior);
      if (_disposed) return;
      _leiter = result.leiter;
      _leiterIndex = _leiter.length - 1;
      await onResumeAt(result.start);
    } on FadenAbortedException {
      if (_disposed) return;
      await onAborted(lo);
    }
  }

  void _emitProgress(int probeNr) {
    if (_disposed || _progressController.isClosed) return;
    _progressController.add(FadenProgress(lo: lo, hi: hi, probeNr: probeNr, maxProbes: fs.maxProbes));
  }

  Future<bool> _frage(int p, int probeNr) async {
    if (_aborted) throw const FadenAbortedException();
    _emitProgress(probeNr);
    await playTone();
    if (_aborted) throw const FadenAbortedException();

    unawaited(playProbe(p).catchError((Object _) {}));
    final completer = Completer<bool>();
    _pendingAnswer = completer;
    final timer = Timer(const Duration(milliseconds: fs.probeLen + fs.answerWindow), () {
      if (!completer.isCompleted) completer.complete(false);
    });
    bool known;
    try {
      known = await completer.future;
    } finally {
      timer.cancel();
      _pendingAnswer = null;
    }

    if (_aborted) throw const FadenAbortedException();
    await onProbeAnswered(p, known);
    return known;
  }

  /// A screen tap or a media-button press (docs/KONZEPT.md: "Kopfhörertaste
  /// oder irgendwo auf den Screen") -- the caller merges both sources and
  /// calls this for either.
  void submitAnswer() {
    final pending = _pendingAnswer;
    if (pending != null && !pending.isCompleted) pending.complete(true);
  }

  /// Long-press abort. Safe to call at any point during [start] (including
  /// before the first probe, or between two probes while the cue tone is
  /// playing) -- the running search stops at its next checkpoint.
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
  /// back through the ladder from the last search result, then resumes
  /// there (another `RESUME`/`source=faden`, per docs/ARCHITEKTUR.md
  /// section 8's closing note -- every ladder step is its own RESUME).
  Future<void> earlier() async {
    if (_disposed || !canGoEarlier) return;
    _leiterIndex = fs.stepEarlier(_leiterIndex);
    final pos = fs.positionAtLeiterIndex(_leiter, _leiterIndex);
    await onResumeAt(pos);
  }

  /// Ends the search for good (the screen was left, with or without a
  /// result): stops any in-flight probe and makes the running [start]
  /// return at its next checkpoint without writing another `PROBE`, without
  /// a `RESUME` and without starting playback. An answer that has not been
  /// recorded yet is dropped, so `lo` never moves (invariant 9).
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    abort();
    unawaited(_progressController.close());
  }
}
