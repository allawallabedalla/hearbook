// Shared test double for widget tests that need an audio handler but no
// real playback: records the journaled transport calls instead of running
// them, and lets the test choose what "playing" reports. Construct it
// inside `tester.runAsync` (the base class creates a real just_audio
// player) with the audio_session channel mocked, as in
// test/ui/faden_screen_test.dart.

import 'dart:async';

import 'package:faden/audio/handler.dart';
import 'package:faden/audio/playback_status.dart';
import 'package:faden/data/journal.dart';
import 'package:faden/domain/event.dart';
import 'package:faden/domain/position.dart';

class FakeAudioHandler extends FadenAudioHandler {
  FakeAudioHandler(Journal journal) : super(journal: journal, deviceId: 'dev-test');

  /// Every `playFrom`/`pauseFrom` call, in order.
  final List<({String action, EventSource source})> calls = [];

  bool fakePlaying = false;
  bool fakeBuffering = false;
  PlaybackFailure? fakeError;
  final StreamController<PlaybackStatus> _status = StreamController<PlaybackStatus>.broadcast();

  /// Sets the reported status and emits it on [statusStream].
  void emitStatus({bool? playing, bool? buffering, PlaybackFailure? error, bool clearError = false}) {
    fakePlaying = playing ?? fakePlaying;
    fakeBuffering = buffering ?? fakeBuffering;
    fakeError = clearError ? null : (error ?? fakeError);
    _status.add(status);
  }

  @override
  PlaybackStatus get status => PlaybackStatus(playing: fakePlaying, buffering: fakeBuffering, error: fakeError);

  @override
  Stream<PlaybackStatus> get statusStream => _status.stream;

  /// The book the handler reports as loaded ([bookId]); unset, the real
  /// handler's (null without `openBook`).
  String? fakeLoadedBookId;

  @override
  String? get bookId => fakeLoadedBookId ?? super.bookId;

  final StreamController<Set<String>> _remote = StreamController<Set<String>>.broadcast();

  /// Emits on [remoteEventsPulled] as a sync that pulled other devices'
  /// events for [bookIds] would.
  void emitRemoteEvents(Set<String> bookIds) => _remote.add(bookIds);

  @override
  Stream<Set<String>> get remoteEventsPulled => _remote.stream;

  @override
  Future<void> dispose() async {
    await _remote.close();
    await _status.close();
    await _speed.close();
    await super.dispose();
  }

  @override
  Future<void> playFrom(EventSource source) async => calls.add((action: 'play', source: source));

  @override
  Future<void> pauseFrom(EventSource source) async => calls.add((action: 'pause', source: source));

  /// Every journaled seek the UI asked for (global ms or chapter index).
  final List<String> seeks = [];

  /// Speeds set through the details sheet.
  final List<double> speeds = [];
  final StreamController<double> _speed = StreamController<double>.broadcast();
  double _currentSpeed = 1.0;

  int awakeCalls = 0;

  @override
  Future<bool> awake({EventSource source = EventSource.ui}) async {
    awakeCalls++;
    return false;
  }

  @override
  Future<void> playPause() => fakePlaying ? pauseFrom(EventSource.ui) : playFrom(EventSource.ui);

  @override
  Future<void> seekBySeconds(int deltaSeconds, {EventSource source = EventSource.ui}) async =>
      seeks.add('by:$deltaSeconds');

  @override
  Future<void> seekToGlobalMs(int globalMs, {EventSource source = EventSource.ui}) async =>
      seeks.add('to:$globalMs');

  @override
  Future<void> seekToChapterStart(int chapterIdx) async => seeks.add('chapter:$chapterIdx');

  @override
  Future<void> setSpeed(double speed) async {
    speeds.add(speed);
    _currentSpeed = speed;
    _speed.add(speed);
  }

  @override
  double get speed => _currentSpeed;

  @override
  Stream<double> get speedStream => _speed.stream;

  @override
  bool get playing => fakePlaying;

  @override
  Stream<bool> get playingStream => const Stream.empty();

  @override
  Stream<Position> get positionStream => const Stream.empty();
}
