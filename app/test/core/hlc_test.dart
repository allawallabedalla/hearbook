import 'package:faden/core/hlc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Hlc.tick (local event)', () {
    test('advances pt to now and resets c when now is ahead', () {
      final last = const Hlc(pt: 1000, c: 5);
      final next = last.tick(2000);
      expect(next, const Hlc(pt: 2000, c: 0));
    });

    test('keeps pt and bumps c when now has not caught up', () {
      final last = const Hlc(pt: 5000, c: 2);
      final next = last.tick(4000);
      expect(next, const Hlc(pt: 5000, c: 3));
    });

    test('keeps pt and bumps c when now equals pt', () {
      final last = const Hlc(pt: 5000, c: 2);
      final next = last.tick(5000);
      expect(next, const Hlc(pt: 5000, c: 3));
    });
  });

  group('Hlc.receive (remote event)', () {
    test('all three pt equal: c is max(c, r.c) + 1', () {
      final last = const Hlc(pt: 1000, c: 3);
      final remote = const Hlc(pt: 1000, c: 7);
      expect(last.receive(remote, 1000), const Hlc(pt: 1000, c: 8));
    });

    test('local pt wins over remote and now: c is local.c + 1', () {
      final last = const Hlc(pt: 9000, c: 4);
      final remote = const Hlc(pt: 1000, c: 99);
      expect(last.receive(remote, 500), const Hlc(pt: 9000, c: 5));
    });

    test('remote pt wins over local and now: c is remote.c + 1', () {
      final last = const Hlc(pt: 1000, c: 4);
      final remote = const Hlc(pt: 9000, c: 2);
      expect(last.receive(remote, 500), const Hlc(pt: 9000, c: 3));
    });

    test('now wins over both: c resets to 0', () {
      final last = const Hlc(pt: 1000, c: 4);
      final remote = const Hlc(pt: 2000, c: 2);
      expect(last.receive(remote, 9000), const Hlc(pt: 9000, c: 0));
    });
  });

  group('ordering', () {
    test('compares by pt first, then c', () {
      expect(const Hlc(pt: 1, c: 9).compareTo(const Hlc(pt: 2, c: 0)), lessThan(0));
      expect(const Hlc(pt: 5, c: 1).compareTo(const Hlc(pt: 5, c: 2)), lessThan(0));
      expect(const Hlc(pt: 5, c: 2).compareTo(const Hlc(pt: 5, c: 2)), 0);
    });
  });

  group('json', () {
    test('round-trips through toJson/fromJson', () {
      final hlc = const Hlc(pt: 1234, c: 5);
      expect(Hlc.fromJson(hlc.toJson()), hlc);
    });
  });
}
