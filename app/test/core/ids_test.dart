import 'package:faden/core/ids.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('eventId returns a UUIDv7 (version nibble 7)', () {
    final id = Ids.eventId();
    expect(id, hasLength(36));
    expect(id[14], '7');
  });

  test('eventId values sort in generation order (time-ordered)', () {
    final a = Ids.eventId();
    final b = Ids.eventId();
    expect(a.compareTo(b), lessThanOrEqualTo(0));
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
