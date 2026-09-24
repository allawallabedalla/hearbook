import 'package:faden/domain/position.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('equal file_hash and offset_ms compare equal', () {
    final a = Position(fileHash: 'abc', offsetMs: 1000);
    final b = Position(fileHash: 'abc', offsetMs: 1000);
    expect(a, b);
    expect(a.hashCode, b.hashCode);
  });

  test('different offset_ms is not equal, even with same file_hash', () {
    final a = Position(fileHash: 'abc', offsetMs: 1000);
    final b = Position(fileHash: 'abc', offsetMs: 2000);
    expect(a, isNot(b));
  });

  test('different file_hash is not equal, even with same offset_ms', () {
    final a = Position(fileHash: 'abc', offsetMs: 1000);
    final b = Position(fileHash: 'def', offsetMs: 1000);
    expect(a, isNot(b));
  });

  test('json round-trip', () {
    final p = Position(fileHash: 'abc123', offsetMs: 42);
    expect(Position.fromJson(p.toJson()), p);
  });
}
