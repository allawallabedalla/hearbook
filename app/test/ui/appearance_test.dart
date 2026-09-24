// Tests ui/theme.dart's resolveFadenTokens (decision E28): Nachtmodus
// always wins; otherwise "Hell"/"Dunkel" are fixed and "Wie iPhone"
// follows the platform brightness. Also checks that the resolved set is
// what widgets below a Faden theme read via FadenTokens.of.

import 'package:faden/data/settings_store.dart';
import 'package:faden/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveFadenTokens', () {
    test('Nachtmodus gives the night tokens whatever the setting and the phone say', () {
      for (final appearance in Appearance.values) {
        for (final brightness in Brightness.values) {
          expect(
            resolveFadenTokens(appearance: appearance, platformBrightness: brightness, nightMode: true),
            same(FadenTokens.night),
            reason: '$appearance / $brightness',
          );
        }
      }
    });

    test('"Hell" is always day, "Dunkel" is always night', () {
      for (final brightness in Brightness.values) {
        expect(
          resolveFadenTokens(
              appearance: Appearance.light, platformBrightness: brightness, nightMode: false),
          same(FadenTokens.day),
        );
        expect(
          resolveFadenTokens(
              appearance: Appearance.dark, platformBrightness: brightness, nightMode: false),
          same(FadenTokens.night),
        );
      }
    });

    test('"Wie iPhone" follows the platform brightness', () {
      expect(
        resolveFadenTokens(
            appearance: Appearance.system, platformBrightness: Brightness.light, nightMode: false),
        same(FadenTokens.day),
      );
      expect(
        resolveFadenTokens(
            appearance: Appearance.system, platformBrightness: Brightness.dark, nightMode: false),
        same(FadenTokens.night),
      );
    });
  });

  testWidgets('FadenTokens.of reads the tokens of the surrounding Faden theme', (tester) async {
    late FadenTokens seen;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFadenTheme(FadenTokens.night),
        home: Builder(builder: (context) {
          seen = FadenTokens.of(context);
          return const SizedBox();
        }),
      ),
    );
    expect(seen, same(FadenTokens.night));
    expect(Theme.of(tester.element(find.byType(SizedBox))).brightness, Brightness.dark);
  });

  test('token lerp switches outright instead of blending colours', () {
    expect(FadenTokens.day.lerp(FadenTokens.night, 0.3), same(FadenTokens.day));
    expect(FadenTokens.day.lerp(FadenTokens.night, 0.7), same(FadenTokens.night));
  });
}
