import 'package:faden/signals/awake.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AwakeGate', () {
    test('allows the first call', () {
      final gate = AwakeGate();
      expect(gate.shouldEmit(0), isTrue);
    });

    test('rejects a second call inside the cooldown window', () {
      final gate = AwakeGate(minInterval: const Duration(seconds: 10));
      expect(gate.shouldEmit(1000), isTrue);
      expect(gate.shouldEmit(1000 + 9999), isFalse);
    });

    test('allows a call exactly at the cooldown boundary', () {
      final gate = AwakeGate(minInterval: const Duration(seconds: 10));
      expect(gate.shouldEmit(1000), isTrue);
      expect(gate.shouldEmit(1000 + 10000), isTrue);
    });

    test('a rejected call does not reset the cooldown', () {
      final gate = AwakeGate(minInterval: const Duration(seconds: 10));
      expect(gate.shouldEmit(0), isTrue);
      expect(gate.shouldEmit(4000), isFalse);
      expect(gate.shouldEmit(8000), isFalse);
      // Still measured from the original emit at 0, not from the rejected
      // attempts at 4000/8000.
      expect(gate.shouldEmit(9999), isFalse);
      expect(gate.shouldEmit(10000), isTrue);
    });
  });
}
