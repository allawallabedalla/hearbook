import 'package:uuid/uuid.dart';

/// Id generation for events and sessions.
///
/// `event_id` is a UUIDv7 (time-ordered, docs/ARCHITEKTUR.md section 5);
/// `device_id`, `session_id` and `book_id` are plain UUIDs (v4) minted once
/// and then reused.
class Ids {
  const Ids._();

  static const Uuid _uuid = Uuid();

  static String eventId() => _uuid.v7();

  static String uuid() => _uuid.v4();
}
