// Decision E75: the softer day look (warm off-white background, white
// cards) keeps every text pairing at 4.5:1 or more (docs/KONZEPT.md
// "Design"), day and night, on the background, on cards, on the quiet
// surfaces and on the open book's highlighted card.

import 'dart:math' as math;

import 'package:faden/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  for (final (name, t) in [('day', FadenTokens.day), ('night', FadenTokens.night)]) {
    group(name, () {
      void check(String what, Color text, Color background) =>
          expect(contrast(text, background), greaterThanOrEqualTo(4.5), reason: '$name: $what');

      test('text on the background', () {
        for (final (what, c) in [('tinte', t.tinte), ('tinteLeise', t.tinteLeise), ('faden', t.faden), ('fehler', t.fehler)]) {
          check(what, c, t.grund);
        }
      });

      test('text on cards and the highlighted card', () {
        for (final bg in [t.karte, t.karteMarkiert]) {
          check('tinte', t.tinte, bg);
          check('leiseAufKarte', t.leiseAufKarte, bg);
          check('fehler', t.fehler, bg);
          check('faden', t.faden, bg);
        }
      });

      test('text on the quiet surfaces', () {
        check('leiseAufFlaeche', t.leiseAufFlaeche, t.flaeche);
        check('leiseAufKarte on a capsule', t.leiseAufKarte, t.flaecheAufKarte);
        check('tinte on a capsule', t.tinte, t.flaecheAufKarte);
      });

      test('the main button\'s symbol', () => check('grund on faden', t.grund, t.faden));
    });
  }

  test('day: a warm off-white with white cards and soft shadows; night: black, no shadows', () {
    expect(FadenTokens.day.grund, const Color(0xFFF4F2EE));
    expect(FadenTokens.day.karte, Colors.white);
    expect(FadenTokens.day.kartenSchatten, isNotEmpty);
    expect(FadenTokens.night.grund, Colors.black);
    expect(FadenTokens.night.kartenSchatten, isEmpty);
    expect(FadenTokens.night.kachelSchatten, isEmpty);
  });
}
