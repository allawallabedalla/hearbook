// Shared test double for widget tests that need an audio handler but no
// real playback: records the journaled transport calls instead of running
// them, and lets the test choose what "playing" reports. Construct it
// inside `tester.runAsync` (the base class creates a real just_audio
// player) with the audio_session channel mocked, as in
// test/ui/faden_screen_test.dart.

import 'dart:async';

import 'package:faden/audio/handler.dart';
import 'package:faden/data/journal.dart';
import 'package:faden/domain/event.dart';
import 'package:faden/domain/position.dart';

class FakeAudioHandler extends FadenAudioHandler {
  FakeAudioHandler(Journal journal) : super(journal: journal, deviceId: 'dev-test');

  /// Every `playFrom`/`pauseFrom` call, in order.
  final List<({String action, EventSource source})> calls = [];

  bool fakePlaying = false;

  @override
  Future<void> playFrom(EventSource source) async => calls.add((action: 'play', source: source));

  @override
  Future<void> pauseFrom(EventSource source) async => calls.add((action: 'pause', source: source));

  @override
  bool get playing => fakePlaying;

  @override
  Stream<bool> get playingStream => const Stream.empty();

  @override
  Stream<Position> get positionStream => const Stream.empty();
}
