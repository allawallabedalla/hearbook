// Smoke test for the day/night theme (ui/theme.dart). The full app
// (lib/main.dart) is not pumped here: it constructs a real just_audio
// AudioPlayer and calls path_provider/audio_service platform channels on
// startup, none of which exist in this headless test environment. Widget
// coverage for the actual screens lives in test/ui/thread_progress_test.dart
// and the pure-logic tests in test/signals/ and test/audio/.

import 'package:faden/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('day and night themes render a Scaffold without error', (tester) async {
    for (final tokens in [FadenTokens.day, FadenTokens.night]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFadenTheme(tokens),
          home: Scaffold(
            backgroundColor: tokens.grund,
            body: Center(child: Text('Faden', style: TextStyle(color: tokens.tinte))),
          ),
        ),
      );
      expect(find.text('Faden'), findsOneWidget);
    }
  });

  test('day and night tokens both meet the documented 4.5:1 text contrast', () {
    // docs/KONZEPT.md "Design": "Alle Text-Kombinationen erreichen
    // mindestens 4,5:1 Kontrast." (WCAG 2.x contrast ratio, using Flutter's
    // own relative-luminance implementation, Color.computeLuminance().)
    for (final tokens in [FadenTokens.day, FadenTokens.night]) {
      expect(_contrastRatio(tokens.tinte, tokens.grund), greaterThanOrEqualTo(4.5));
      expect(_contrastRatio(tokens.tinteLeise, tokens.grund), greaterThanOrEqualTo(4.5));
    }
  });
}

double _contrastRatio(Color a, Color b) {
  final la = a.computeLuminance() + 0.05;
  final lb = b.computeLuminance() + 0.05;
  return la > lb ? la / lb : lb / la;
}
