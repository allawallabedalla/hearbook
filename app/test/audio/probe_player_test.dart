// Tests the probe-length bound of audio/probe_player.dart (docs/ARCHITEKTUR.md
// section 8: "Eine Probe endet spätestens am Dateiende"). The player itself
// wraps real platform audio and is not exercised here.

import 'package:faden/audio/probe_player.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProbePlayer.probePlayMs', () {
    test('a probe well inside the file plays its full length', () {
      expect(
        ProbePlayer.probePlayMs(offsetMs: 10000, probeLenMs: 4000, fileDurationMs: 60000),
        4000,
      );
    });

    test('player duration unknown (null): the manifest duration still cuts at the file end', () {
      expect(
        ProbePlayer.probePlayMs(
          offsetMs: 58500,
          probeLenMs: 4000,
          fileDurationMs: 60000,
          playerDurationMs: null,
        ),
        1500,
      );
    });

    test('a shorter player-reported duration tightens the bound', () {
      expect(
        ProbePlayer.probePlayMs(
          offsetMs: 58000,
          probeLenMs: 4000,
          fileDurationMs: 60000,
          playerDurationMs: 59000,
        ),
        1000,
      );
    });

    test('a longer player-reported duration never extends past the manifest file end', () {
      expect(
        ProbePlayer.probePlayMs(
          offsetMs: 58000,
          probeLenMs: 4000,
          fileDurationMs: 60000,
          playerDurationMs: 90000,
        ),
        2000,
      );
    });

    test('never negative, even at or past the file end', () {
      expect(ProbePlayer.probePlayMs(offsetMs: 60000, probeLenMs: 4000, fileDurationMs: 60000), 0);
      expect(ProbePlayer.probePlayMs(offsetMs: 61000, probeLenMs: 4000, fileDurationMs: 60000), 0);
    });
  });
}
