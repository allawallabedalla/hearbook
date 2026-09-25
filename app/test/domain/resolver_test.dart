// Loads every JSON file in ../spec/vectors (docs/ARCHITEKTUR.md section 11:
// "Resolver-Tests laden ../spec/vectors/*.json") and checks resolve()
// against its `expect` block. Vectors are read dynamically -- adding a new
// spec/vectors/*.json file adds a test case here without touching this
// file, so `expect` in a vector's `expect` block is the sole source of
// truth for what "correct" means for that case, rather than duplicating 8
// hand-written test bodies.

import 'dart:convert';
import 'dart:io';

import 'package:faden/domain/event.dart';
import 'package:faden/domain/manifest.dart';
import 'package:faden/domain/position.dart';
import 'package:faden/domain/resolver.dart';
import 'package:flutter_test/flutter_test.dart';

Position _positionFromJson(Map<String, dynamic> json) => Position(
      fileHash: json['file_hash'] as String,
      offsetMs: json['offset_ms'] as int,
    );

void main() {
  final dir = Directory('../spec/vectors');

  test('spec/vectors directory is present and non-empty', () {
    expect(
      dir.existsSync(),
      isTrue,
      reason: 'expected ${dir.path} (run `flutter test` from app/, cwd: ${Directory.current.path})',
    );
  });

  if (!dir.existsSync()) return; // the assertion above already failed loudly

  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('at least the 8 resolver vectors from section 7 are present', () {
    expect(files.length, greaterThanOrEqualTo(8));
  });

  for (final file in files) {
    final name = file.uri.pathSegments.last;
    test('resolver vector: $name', () {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

      final settingsJson = json['settings'] as Map<String, dynamic>?;
      final nightWindow = settingsJson?['night_window'] as Map<String, dynamic>?;
      final settings = nightWindow == null
          ? const ResolverSettings()
          : ResolverSettings(
              nightStartMin: nightWindow['start_min'] as int,
              nightEndMin: nightWindow['end_min'] as int,
            );

      final manifest = Manifest.fromJson(json['manifest'] as Map<String, dynamic>);
      final events = (json['events'] as List)
          .map((e) => Event.fromJson(e as Map<String, dynamic>))
          .toList();

      final state = resolve(events, manifest, settings: settings);

      final expectJson = json['expect'] as Map<String, dynamic>;
      expect(
        state.position,
        _positionFromJson(expectJson['position'] as Map<String, dynamic>),
        reason: 'position',
      );
      expect(state.globalMs, expectJson['global_ms'], reason: 'global_ms');
      expect(
        state.lastAwake,
        _positionFromJson(expectJson['last_awake'] as Map<String, dynamic>),
        reason: 'last_awake',
      );
      expect(
        state.stop,
        _positionFromJson(expectJson['stop'] as Map<String, dynamic>),
        reason: 'stop',
      );
      expect(state.sleepSuspected, expectJson['sleep_suspected'], reason: 'sleep_suspected');
      final expectedHistory = (expectJson['history'] as List)
          .map((p) => _positionFromJson(p as Map<String, dynamic>))
          .toList();
      expect(state.history, expectedHistory, reason: 'history');
      expect(state.finished, expectJson['finished'], reason: 'finished');
      expect(
        state.needsConfirmation,
        expectJson['needs_confirmation'],
        reason: 'needs_confirmation',
      );
      // Optional keys (decision E84): what the player's offer and the
      // learning read from the winning session.
      if (expectJson.containsKey('in_night_window')) {
        expect(state.inNightWindow, expectJson['in_night_window'], reason: 'in_night_window');
      }
      if (expectJson.containsKey('stop_reason')) {
        expect(state.stopReason?.wireName, expectJson['stop_reason'], reason: 'stop_reason');
      }
    });
  }
}
