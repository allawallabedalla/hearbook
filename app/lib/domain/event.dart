import '../core/hlc.dart';
import 'position.dart';

/// Event types from docs/ARCHITEKTUR.md section 5.
enum EventType {
  play('PLAY'),
  seek('SEEK'),
  resume('RESUME'),
  undo('UNDO'),
  heartbeat('HEARTBEAT'),
  pause('PAUSE'),
  awake('AWAKE'),
  sleepHint('SLEEP_HINT'),
  probe('PROBE'),
  finished('FINISHED');

  final String wireName;

  const EventType(this.wireName);

  static EventType fromWire(String wireName) => EventType.values.firstWhere(
        (t) => t.wireName == wireName,
        orElse: () => throw ArgumentError('unknown event type: $wireName'),
      );

  /// Section 5 "Absicht" column, and section 7 rule 2: these types decide
  /// which session currently "wins".
  bool get isIntent =>
      this == EventType.play ||
      this == EventType.seek ||
      this == EventType.resume ||
      this == EventType.undo;

  /// Section 5 "Wach-Beleg" column for the types that are awake proofs
  /// whatever their source (PAUSE only is, from the UI).
  bool get alwaysAwakeProof =>
      isIntent || this == EventType.awake || this == EventType.finished;
}

/// Event sources from docs/ARCHITEKTUR.md section 5.
enum EventSource {
  ui('ui'),
  mediaButton('media_button'),
  timer('timer'),
  system('system'),
  faden('faden');

  final String wireName;

  const EventSource(this.wireName);

  static EventSource fromWire(String wireName) => EventSource.values.firstWhere(
        (s) => s.wireName == wireName,
        orElse: () => throw ArgumentError('unknown event source: $wireName'),
      );
}

/// A single event per docs/ARCHITEKTUR.md section 5. Pure data: the app
/// never overwrites progress (invariant 2), it only ever appends events
/// like this one, and the Resolver derives state from them.
class Event {
  final String eventId;
  final String deviceId;
  final String sessionId;
  final String bookId;
  final String manifestId;
  final EventType type;
  final String fileHash;
  final int offsetMs;
  final Hlc hlc;
  final int wallMs;
  final int tzMin;
  final EventSource source;
  final Map<String, dynamic> data;

  const Event({
    required this.eventId,
    required this.deviceId,
    required this.sessionId,
    required this.bookId,
    required this.manifestId,
    required this.type,
    required this.fileHash,
    required this.offsetMs,
    required this.hlc,
    required this.wallMs,
    required this.tzMin,
    required this.source,
    this.data = const {},
  });

  factory Event.fromJson(Map<String, dynamic> json) => Event(
        eventId: json['event_id'] as String,
        deviceId: json['device_id'] as String,
        sessionId: json['session_id'] as String,
        bookId: json['book_id'] as String,
        manifestId: json['manifest_id'] as String,
        type: EventType.fromWire(json['type'] as String),
        fileHash: json['file_hash'] as String,
        offsetMs: json['offset_ms'] as int,
        hlc: Hlc.fromJson(json['hlc'] as Map<String, dynamic>),
        wallMs: json['wall_ms'] as int,
        tzMin: json['tz_min'] as int,
        source: EventSource.fromWire(json['source'] as String),
        data: json['data'] == null
            ? const {}
            : Map<String, dynamic>.from(json['data'] as Map),
      );

  Map<String, dynamic> toJson() => {
        'event_id': eventId,
        'device_id': deviceId,
        'session_id': sessionId,
        'book_id': bookId,
        'manifest_id': manifestId,
        'type': type.wireName,
        'file_hash': fileHash,
        'offset_ms': offsetMs,
        'hlc': hlc.toJson(),
        'wall_ms': wallMs,
        'tz_min': tzMin,
        'source': source.wireName,
        'data': data,
      };

  /// `(file_hash, offset_ms)` this event carries (invariant 1).
  Position get position => Position(fileHash: fileHash, offsetMs: offsetMs);

  /// Section 5 "Wach-Beleg" column: whether this event counts as proof the
  /// listener was awake. Every intent event does, as do `AWAKE` and
  /// `FINISHED`; `PAUSE` only counts when it came from the UI (a listener
  /// falling asleep with headphones on triggers a `PAUSE` via the media
  /// button or the system, not the UI).
  bool get isAwakeProof =>
      type.alwaysAwakeProof || (type == EventType.pause && source == EventSource.ui);

  Event copyWith({
    String? eventId,
    String? deviceId,
    String? sessionId,
    String? bookId,
    String? manifestId,
    EventType? type,
    String? fileHash,
    int? offsetMs,
    Hlc? hlc,
    int? wallMs,
    int? tzMin,
    EventSource? source,
    Map<String, dynamic>? data,
  }) =>
      Event(
        eventId: eventId ?? this.eventId,
        deviceId: deviceId ?? this.deviceId,
        sessionId: sessionId ?? this.sessionId,
        bookId: bookId ?? this.bookId,
        manifestId: manifestId ?? this.manifestId,
        type: type ?? this.type,
        fileHash: fileHash ?? this.fileHash,
        offsetMs: offsetMs ?? this.offsetMs,
        hlc: hlc ?? this.hlc,
        wallMs: wallMs ?? this.wallMs,
        tzMin: tzMin ?? this.tzMin,
        source: source ?? this.source,
        data: data ?? this.data,
      );
}

/// Total order over events per section 5: `(hlc.pt, hlc.c, device_id,
/// event_id)`.
int compareEvents(Event a, Event b) {
  final hlcCmp = a.hlc.compareTo(b.hlc);
  if (hlcCmp != 0) return hlcCmp;
  final deviceCmp = a.deviceId.compareTo(b.deviceId);
  if (deviceCmp != 0) return deviceCmp;
  return a.eventId.compareTo(b.eventId);
}
