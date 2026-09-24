import 'package:faden/core/ids.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('eventId returns a UUIDv7 (version nibble 7)', () {
    final id = Ids.eventId();
    expect(id, hasLength(36));
    expect(id[14], '7');
  });

  test('eventId values share the UUIDv7 millisecond-timestamp prefix '
      'when generated back-to-back (the random suffix is not ordered '
      'within the same millisecond, so this only checks the prefix)', () {
    final a = Ids.eventId();
    final b = Ids.eventId();
    String msPrefix(String id) => id.substring(0, 8) + id.substring(9, 13);
    // Same millisecond (near-certain back-to-back) -> equal prefixes;
    // the next millisecond -> a strictly greater prefix. Either way,
    // never decreasing.
    expect(msPrefix(a).compareTo(msPrefix(b)), lessThanOrEqualTo(0));
  });

  test('uuid returns a version-4 UUID', () {
    final id = Ids.uuid();
    expect(id, hasLength(36));
    expect(id[14], '4');
  });

  test('generated ids are unique', () {
    final ids = List.generate(50, (_) => Ids.eventId()).toSet();
    expect(ids, hasLength(50));
  });
}
