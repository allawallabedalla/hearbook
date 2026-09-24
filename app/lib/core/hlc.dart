/// Hybrid Logical Clock, docs/ARCHITEKTUR.md section 5.
///
/// `pt` is a physical-time component in milliseconds since the Unix epoch,
/// `c` a logical counter that orders events sharing the same `pt`. This
/// class is pure: it never reads the wall clock itself, callers always pass
/// the current time in as `nowMs` so behaviour stays deterministic and
/// testable.
class Hlc implements Comparable<Hlc> {
  final int pt;
  final int c;

  const Hlc({required this.pt, required this.c});

  factory Hlc.fromJson(Map<String, dynamic> json) =>
      Hlc(pt: json['pt'] as int, c: json['c'] as int);

  Map<String, dynamic> toJson() => {'pt': pt, 'c': c};

  /// Next HLC for a locally generated event. `this` is the device's last
  /// HLC, `nowMs` its current wall clock.
  Hlc tick(int nowMs) {
    final newPt = pt > nowMs ? pt : nowMs;
    final newC = newPt == pt ? c + 1 : 0;
    return Hlc(pt: newPt, c: newC);
  }

  /// Next HLC when receiving a remote event. `this` is the device's last
  /// HLC, `remote` the HLC carried by the incoming event, `nowMs` its
  /// current wall clock.
  Hlc receive(Hlc remote, int nowMs) {
    final newPt = [pt, remote.pt, nowMs].reduce((a, b) => a > b ? a : b);
    final int newC;
    if (newPt == pt && newPt == remote.pt) {
      newC = (c > remote.c ? c : remote.c) + 1;
    } else if (newPt == pt) {
      newC = c + 1;
    } else if (newPt == remote.pt) {
      newC = remote.c + 1;
    } else {
      newC = 0;
    }
    return Hlc(pt: newPt, c: newC);
  }

  @override
  int compareTo(Hlc other) {
    if (pt != other.pt) return pt.compareTo(other.pt);
    return c.compareTo(other.c);
  }

  @override
  bool operator ==(Object other) =>
      other is Hlc && pt == other.pt && c == other.c;

  @override
  int get hashCode => Object.hash(pt, c);

  @override
  String toString() => 'Hlc(pt: $pt, c: $c)';
}
