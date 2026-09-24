import 'package:faden/core/hlc.dart';
import 'package:faden/domain/event.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> baseJson({
  String type = 'PLAY',
  String source = 'ui',
}) =>
    {
      'event_id': '019105c1-0000-7000-8000-000000000001',
      'device_id': '11111111-1111-1111-1111-111111111111',
      'session_id': '22222222-2222-2222-2222-222222222222',
      'book_id': '33333333-3333-3333-3333-333333333333',
      'manifest_id': 'deadbeef',
      'type': type,
      'file_hash': 'abc123',
      'offset_ms': 1000,
      'hlc': {'pt': 5000, 'c': 1},
      'wall_ms': 1234567,
      'tz_min': 120,
      'source': source,
      'data': {},
    };

void main() {
  test('parses every field from the section 5 JSON shape', () {
    final e = Event.fromJson(baseJson());
    expect(e.eventId, '019105c1-0000-7000-8000-000000000001');
    expect(e.deviceId, '11111111-1111-1111-1111-111111111111');
    expect(e.sessionId, '22222222-2222-2222-2222-222222222222');
    expect(e.bookId, '33333333-3333-3333-3333-333333333333');
    expect(e.manifestId, 'deadbeef');
    expect(e.type, EventType.play);
    expect(e.fileHash, 'abc123');
    expect(e.offsetMs, 1000);
    expect(e.hlc, const Hlc(pt: 5000, c: 1));
    expect(e.wallMs, 1234567);
    expect(e.tzMin, 120);
    expect(e.source, EventSource.ui);
    expect(e.data, <String, dynamic>{});
  });

  test('json round-trip', () {
    final e = Event.fromJson(baseJson(type: 'PROBE', source: 'faden'));
    expect(Event.fromJson(e.toJson()).toJson(), e.toJson());
  });

  test('all 10 event types parse and re-serialize to the same string', () {
    for (final type in EventType.values) {
      final e = Event.fromJson(baseJson(type: type.wireName));
      expect(e.type, type);
      expect(e.toJson()['type'], type.wireName);
    }
  });

  test('all 5 sources parse and re-serialize to the same string', () {
    for (final source in EventSource.values) {
      final e = Event.fromJson(baseJson(source: source.wireName));
      expect(e.source, source);
      expect(e.toJson()['source'], source.wireName);
    }
  });

  group('isIntent (section 7 rule 2 / section 5 "Absicht" column)', () {
    test('PLAY, SEEK, RESUME, UNDO are intent events', () {
      for (final t in [EventType.play, EventType.seek, EventType.resume, EventType.undo]) {
        expect(t.isIntent, isTrue, reason: t.wireName);
      }
    });

    test('all other types are not intent events', () {
      for (final t in EventType.values) {
        if ([EventType.play, EventType.seek, EventType.resume, EventType.undo].contains(t)) {
          continue;
        }
        expect(t.isIntent, isFalse, reason: t.wireName);
      }
    });
  });

  group('isAwakeProof (section 5 "Wach-Beleg" column)', () {
    test('PLAY, SEEK, RESUME, UNDO, AWAKE, FINISHED are always awake proof', () {
      final e = Event.fromJson(baseJson(type: 'PLAY', source: 'ui'));
      for (final t in [
        EventType.play,
        EventType.seek,
        EventType.resume,
        EventType.undo,
        EventType.awake,
        EventType.finished,
      ]) {
        expect(e.copyWith(type: t).isAwakeProof, isTrue, reason: t.wireName);
      }
    });

    test('PAUSE is awake proof only when source is ui', () {
      final uiPause = Event.fromJson(baseJson(type: 'PAUSE', source: 'ui'));
      final buttonPause = Event.fromJson(baseJson(type: 'PAUSE', source: 'media_button'));
      expect(uiPause.isAwakeProof, isTrue);
      expect(buttonPause.isAwakeProof, isFalse);
    });

    test('HEARTBEAT, SLEEP_HINT, PROBE are never awake proof', () {
      for (final t in [EventType.heartbeat, EventType.sleepHint, EventType.probe]) {
        final e = Event.fromJson(baseJson(type: t.wireName, source: 'ui'));
        expect(e.isAwakeProof, isFalse, reason: t.wireName);
      }
    });
  });

  test('position getter combines file_hash and offset_ms', () {
    final e = Event.fromJson(baseJson());
    expect(e.position.fileHash, 'abc123');
    expect(e.position.offsetMs, 1000);
  });
}
