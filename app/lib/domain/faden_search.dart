/// Faden-Suche ("thread search"), docs/ARCHITEKTUR.md section 8. Faithful
/// port of the JS reference implementation in prototype/faden.html (already
/// validated there against 20,000 randomized listener simulations): same
/// parameters, same control flow, same `snap()` tolerance rule. The only
/// deliberate adaptation is that all positions are `int` milliseconds
/// throughout (the JS version briefly produces a float when `(hi - lo)` is
/// odd); `offset_ms` is an integer everywhere else in this app (section 5),
/// and using `~/` (floor division) instead of `/` never changes which
/// second a probe lands in, so no behaviour changes and no
/// ARCHITEKTUR.md section 13 entry is needed for it.
///
/// Invariant 9 (CLAUDE.md): the search must never skip unheard content --
/// `lo` only ever advances because the listener answered "I know this" at
/// that exact position. `hi` shrinking on a "no" never moves `lo`.
library;

const int target = 30000; // ms, section 8 target accuracy
const int maxProbes = 8; // including probe 1
const int probeLen = 4000; // ms
const int answerWindow = 3000; // ms after the probe ends
const int firstOffset = 25000; // ms before the stop point
const int preroll = 2000; // ms

/// Asks the listener about the probe at `p` (the `probeNr`-th probe taken
/// so far, 1-based) and resolves to whether they know it ("kenne ich").
typedef Frage = Future<bool> Function(int p, int probeNr);

class FadenSearchResult {
  /// Where playback should resume.
  final int start;

  /// Every position the search settled on, in order: `leiter[0]` is the
  /// starting `lo`; each subsequent entry is a probe the listener knew.
  /// Used by "Früher" ([stepEarlier]/[positionAtLeiterIndex]) to walk back.
  final List<int> leiter;

  const FadenSearchResult({required this.start, required this.leiter});
}

int _max(int a, int b) => a > b ? a : b;
int _abs(int a) => a < 0 ? -a : a;

/// Snaps `x` to the nearest known sentence start (`pausen`) within `tol`,
/// but only if that sentence start leaves room for a full probe on both
/// sides (`lo + probeLen < s < hi - probeLen`). Returns `x` unchanged if no
/// candidate qualifies.
int snap(int x, int lo, int hi, int tol, List<int> pausen) {
  final candidates = pausen.where(
    (s) => lo + probeLen < s && s < hi - probeLen && _abs(s - x) <= tol,
  );
  if (candidates.isEmpty) return x;
  return candidates.reduce((best, s) => _abs(s - x) < _abs(best - x) ? s : best);
}

/// Binary-searches `[lo, hi]` (both global ms of the active manifest, `lo`
/// = last_awake, `hi` = stop) for the last position the listener still
/// recognizes, asking at most [maxProbes] short probes via [frage].
///
/// `prior` is an optional first guess from local health data (section 9):
/// when given, it replaces the first bisection midpoint instead of probe 1
/// (the "Fehlalarm-Test" / false-alarm check against `hi - firstOffset`)
/// still running as usual.
Future<FadenSearchResult> fadenSuche(
  int lo,
  int hi,
  List<int> pausen,
  Frage frage, {
  int? prior,
}) async {
  if (hi - lo <= target) {
    return FadenSearchResult(start: _max(lo - preroll, 0), leiter: [lo]);
  }

  final leiter = <int>[lo];
  var proben = 0;

  if (prior == null) {
    final p = snap(hi - firstOffset, lo, hi, 2000, pausen);
    proben += 1;
    if (await frage(p, proben)) {
      return FadenSearchResult(start: p, leiter: [lo, p]);
    }
    hi = p;
  }

  while (hi - lo > target && proben < maxProbes) {
    final x = (proben == 0 && prior != null) ? prior : lo + (hi - lo) ~/ 2;
    final tol = _max(2000, (0.03 * (hi - lo)).round());
    final p = snap(x, lo, hi, tol, pausen);
    proben += 1;
    if (await frage(p, proben)) {
      lo = p;
      leiter.add(p);
    } else {
      hi = p;
    }
  }

  final start = lo == leiter[0] ? _max(lo - preroll, 0) : lo;
  return FadenSearchResult(start: start, leiter: leiter);
}

/// "Früher": steps exactly one entry back through `leiter` from
/// `currentIndex`, never below 0.
int stepEarlier(int currentIndex) => currentIndex > 0 ? currentIndex - 1 : 0;

/// The playback position for `leiter[index]`: the raw ladder entry, except
/// at index 0 (the original `lo`) which gets [preroll] subtracted, same as
/// the very first [FadenSearchResult.start] when the listener never
/// answered.
int positionAtLeiterIndex(List<int> leiter, int index) {
  if (index == 0) return _max(leiter[0] - preroll, 0);
  return leiter[index];
}
