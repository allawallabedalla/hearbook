// Checks lib/l10n/strings.dart word-for-word against lib/l10n/app_de.arb
// (decision E14, docs/ARCHITEKTUR.md section 13): the arb file stays the
// documented, human-edited source of every UI text from docs/KONZEPT.md,
// and this test is what keeps the Dart map an exact, uncached copy of it
// rather than a place strings can quietly drift out of sync.

import 'dart:convert';
import 'dart:io';

import 'package:faden/l10n/strings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AppStrings.values matches l10n/app_de.arb exactly', () {
    final file = File('lib/l10n/app_de.arb');
    expect(file.existsSync(), isTrue, reason: 'expected ${file.path} to exist');

    final arb = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final arbEntries = <String, String>{
      for (final entry in arb.entries)
        if (!entry.key.startsWith('@')) entry.key: entry.value as String,
    };

    expect(arbEntries.keys.toSet(), equals(AppStrings.values.keys.toSet()),
        reason: 'strings.dart and app_de.arb must declare the same keys');
    for (final key in arbEntries.keys) {
      expect(AppStrings.values[key], equals(arbEntries[key]), reason: 'key "$key" differs');
    }
  });

  test('every arb value has a "@" description or is a plain concept text', () {
    final file = File('lib/l10n/app_de.arb');
    final arb = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    for (final key in arb.keys) {
      if (key.startsWith('@')) continue;
      expect(arb[key], isA<String>(), reason: 'value for "$key" must be a string');
    }
  });

  test('no raw placeholders or English leftovers in plain texts', () {
    for (final entry in AppStrings.values.entries) {
      final placeholders = RegExp(r'\{(\w+)\}').allMatches(entry.value).map((m) => m.group(1)).toSet();
      final known = {'n', 'max', 'total', 'chapter', 'time', 'size', 'title', 'h', 'm', 'duration', 'source'};
      expect(known.containsAll(placeholders), isTrue, reason: '${entry.key}: $placeholders');
      expect(entry.value.contains('Neu starten'), isFalse, reason: entry.key);
    }
  });

  group('formatters substitute placeholders', () {
    test('undoHint matches the KONZEPT.md pattern', () {
      expect(AppStrings.undoHint(AppStrings.chapterLabel(7), '23:41'),
          'Zurück zu Kapitel 7, 23:41');
    });

    test('chapterLabel', () => expect(AppStrings.chapterLabel(3), 'Kapitel 3'));

    test('chapterOfTotal',
        () => expect(AppStrings.chapterOfTotal(2, 9), 'Kapitel 2 von 9'));

    test('remainingTime', () => expect(AppStrings.remainingTime('12:34'), 'noch 12:34'));

    test('sleepTimerMinutes', () => expect(AppStrings.sleepTimerMinutes(30), '30 Min.'));

    test('reviewDialogOption', () => expect(AppStrings.reviewDialogOption(1), 'Reihenfolge 1'));

    test('durations', () {
      expect(AppStrings.durationHoursMinutes(3, 45), '3 Std. 45 Min.');
      expect(AppStrings.durationHours(5), '5 Std.');
      expect(AppStrings.durationMinutes(12), '12 Min.');
    });

    test('settingsHealthDataOptInDescription names the source', () {
      expect(AppStrings.settingsHealthDataOptInDescription(AppStrings.healthSourceIos), contains('aus Health,'));
    });

    test('fadenProbeCounter matches the KONZEPT.md pattern',
        () => expect(AppStrings.fadenProbeCounter(3, 8), 'Probe 3 von höchstens 8'));
  });
}
