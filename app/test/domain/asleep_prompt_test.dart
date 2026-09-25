// Tests domain/asleep_prompt.dart (decision E84): the listening stretch
// since the last awake proof, and when "Eingeschlafen?" asks -- over an
// hour, or 20 min in the night window; never in the car, never twice per
// stretch, never while a Faden search runs.

import 'package:faden/core/hlc.dart';
import 'package:faden/domain/asleep_prompt.dart';
import 'package:faden/domain/event.dart';
import 'package:faden/domain/pause_reason.dart';
import 'package:flutter_test/flutter_test.dart';

const int _min = 60000;

Event _e(
  EventType type,
  int atMin, {
  EventSource source = EventSource.ui,
  Map<String, dynamic> data = const {},
}) =>
    Event(
      eventId: 'e$atMin${type.wireName}',
      deviceId: 'd',
      sessionId: 's',
      bookId: 'b',
      manifestId: 'm',
      type: type,
      fileHash: 'f',
      offsetMs: atMin * _min,
      hlc: Hlc(pt: atMin * _min, c: 0),
      wallMs: atMin * _min,
      tzMin: 0,
      source: source,
      data: data,
    );

/// Feeds [events] with their offset as global ms.
ListeningStretchTracker _track(List<Event> events) {
  final t = ListeningStretchTracker();
  for (final e in events) {
    t.onEvent(e, globalMs: e.offsetMs);
  }
  return t;
}

AsleepAsk _due(
  ListeningStretch s, {
  bool night = false,
  bool car = false,
  int? asked,
  bool faden = false,
}) =>
    asleepPromptDue(stretch: s, inNightWindow: night, carRoute: car, askedStretchId: asked, fadenActive: faden);

void main() {
  test('the thresholds are 60 min, and 20 min in the night window', () {
    expect(asleepPromptAfterMs, 60 * _min);
    expect(nightStretchSuspectMs, 20 * _min);
  });

  group('ListeningStretchTracker', () {
    test('nothing played: idle, nothing listened', () {
      final s = ListeningStretchTracker().snapshot(10 * _min);
      expect(s.state, StretchState.idle);
      expect(s.listenedMs, 0);
      expect(s.lastAwakeGlobalMs, isNull);
    });

    test('PLAY starts a stretch; heartbeats do not reset it', () {
      final t = _track([
        _e(EventType.play, 0),
        _e(EventType.heartbeat, 30, source: EventSource.ui),
      ]);
      final s = t.snapshot(61 * _min);
      expect(s.state, StretchState.playing);
      expect(s.listenedMs, 61 * _min);
      expect(s.lastAwakeGlobalMs, 0);
    });

    test('a touch (AWAKE) resets the stretch and bumps its id', () {
      final t = _track([_e(EventType.play, 0)]);
      final before = t.snapshot(30 * _min).id;
      t.onEvent(_e(EventType.awake, 30), globalMs: 30 * _min);
      final s = t.snapshot(40 * _min);
      expect(s.id, isNot(before));
      expect(s.listenedMs, 10 * _min);
      expect(s.lastAwakeGlobalMs, 30 * _min);
    });

    test('a timer pause stops counting; the stretch stopped by itself', () {
      final t = _track([
        _e(EventType.play, 0),
        _e(EventType.pause, 45, source: EventSource.timer, data: {'reason': 'timer'}),
        _e(EventType.sleepHint, 45, source: EventSource.timer),
      ]);
      final s = t.snapshot(8 * 60 * _min);
      expect(s.state, StretchState.stoppedByItself);
      expect(s.listenedMs, 45 * _min);
      expect(s.lastListenWallMs, 45 * _min);
      expect(s.stopReason, PauseReason.timer);
    });

    test('a pause on the screen is an awake proof: idle, nothing to ask', () {
      final t = _track([
        _e(EventType.play, 0),
        _e(EventType.pause, 90, data: {'reason': 'conscious'}),
      ]);
      final s = t.snapshot(100 * _min);
      expect(s.state, StretchState.idle);
      expect(s.listenedMs, 0);
    });

    test('the book end (FINISHED) stops the stretch without proving anything', () {
      final t = _track([
        _e(EventType.play, 0),
        _e(EventType.finished, 70, source: EventSource.system),
      ]);
      final s = t.snapshot(9 * 60 * _min);
      expect(s.state, StretchState.stoppedByItself);
      expect(s.listenedMs, 70 * _min);
      expect(s.lastAwakeGlobalMs, 0);
    });

    test('a pause in the car marks the stretch', () {
      final t = _track([
        _e(EventType.play, 0),
        _e(EventType.pause, 80, source: EventSource.system, data: {'reason': 'route_lost', 'route': 'car'}),
      ]);
      expect(t.snapshot(90 * _min).stoppedInCar, isTrue);
    });

    test('a PROBE is no awake proof', () {
      final t = _track([
        _e(EventType.play, 0),
        _e(EventType.pause, 70, source: EventSource.system, data: {'reason': 'unconscious'}),
        _e(EventType.probe, 71, source: EventSource.faden),
      ]);
      expect(t.snapshot(80 * _min).listenedMs, 70 * _min);
    });

    test('reset forgets everything (another book)', () {
      final t = _track([_e(EventType.play, 0)]);
      t.reset();
      expect(t.snapshot(90 * _min).state, StretchState.idle);
    });
  });

  group('asleepPromptDue', () {
    final playing65 = _track([_e(EventType.play, 0)]).snapshot(65 * _min);
    final playing25 = _track([_e(EventType.play, 0)]).snapshot(25 * _min);

    test('asks after an hour, day or night', () {
      expect(_due(playing65), AsleepAsk.overAnHour);
      expect(_due(playing65, night: true), AsleepAsk.overAnHour);
    });

    test('not before an hour by day', () {
      expect(_due(_track([_e(EventType.play, 0)]).snapshot(59 * _min)), AsleepAsk.no);
      expect(_due(playing25), AsleepAsk.no);
    });

    test('in the night window already after 20 min', () {
      expect(_due(playing25, night: true), AsleepAsk.nightStretch);
      expect(_due(_track([_e(EventType.play, 0)]).snapshot(19 * _min), night: true), AsleepAsk.no);
    });

    test('also when it stopped by itself', () {
      final stopped = _track([
        _e(EventType.play, 0),
        _e(EventType.pause, 62, source: EventSource.system, data: {'reason': 'unconscious'}),
      ]).snapshot(9 * 60 * _min);
      expect(_due(stopped), AsleepAsk.overAnHour);
    });

    test('never while CarPlay is the output, nor after a stop in the car', () {
      expect(_due(playing65, car: true), AsleepAsk.no);
      final carStop = _track([
        _e(EventType.play, 0),
        _e(EventType.pause, 70, source: EventSource.system, data: {'reason': 'unconscious', 'route': 'car'}),
      ]).snapshot(80 * _min);
      expect(_due(carStop), AsleepAsk.no);
    });

    test('once per stretch', () {
      expect(_due(playing65, asked: playing65.id), AsleepAsk.no);
      expect(_due(playing65, asked: playing65.id - 1), AsleepAsk.overAnHour);
    });

    test('never while a Faden search runs, nor after a conscious stop', () {
      expect(_due(playing65, faden: true), AsleepAsk.no);
      final idle = _track([
        _e(EventType.play, 0),
        _e(EventType.pause, 70, data: {'reason': 'conscious'}),
      ]).snapshot(80 * _min);
      expect(_due(idle), AsleepAsk.no);
    });
  });

  group('asleepPromptBody', () {
    test('chooses the text by threshold and whether it still plays', () {
      expect(asleepPromptBody(AsleepAsk.overAnHour, playing: true, listenedMs: 65 * _min),
          (key: AsleepBody.playingOverAnHour, minutes: 65));
      expect(asleepPromptBody(AsleepAsk.overAnHour, playing: false, listenedMs: 65 * _min),
          (key: AsleepBody.stoppedOverAnHour, minutes: 65));
      expect(asleepPromptBody(AsleepAsk.nightStretch, playing: true, listenedMs: 25 * _min + 40000),
          (key: AsleepBody.playingMinutes, minutes: 25));
      expect(asleepPromptBody(AsleepAsk.nightStretch, playing: false, listenedMs: 31 * _min),
          (key: AsleepBody.stoppedMinutes, minutes: 31));
    });
  });
}
