// Direct unit tests for resolver rule 8 (docs/ARCHITEKTUR.md section 7):
// a file_hash missing from the active manifest sets needs_confirmation and
// leaves the position untouched, rather than the resolver guessing or
// crashing. This complements the 8 spec/vectors cases (which all use
// files present in their manifest) with the one behaviour they don't
// exercise.

import 'package:faden/domain/event.dart';
import 'package:faden/core/hlc.dart';
import 'package:faden/domain/manifest.dart';
import 'package:faden/domain/position.dart';
import 'package:faden/domain/resolver.dart';
import 'package:flutter_test/flutter_test.dart';

Event _event({
  required String id,
  required EventType type,
  required String fileHash,
  required int offsetMs,
  required int pt,
  EventSource source = EventSource.ui,
}) =>
    Event(
      eventId: id,
      deviceId: 'dev-a',
      sessionId: 's1',
      bookId: 'book-1',
      manifestId: 'm1',
      type: type,
      fileHash: fileHash,
      offsetMs: offsetMs,
      hlc: Hlc(pt: pt, c: 0),
      wallMs: pt,
      tzMin: 0,
      source: source,
    );

void main() {
  final manifest = const Manifest(
    manifestId: 'm1',
    files: [ManifestFile(idx: 0, fileHash: 'f1', durationMs: 3600000)],
  );

  test('position file_hash missing from the manifest sets needs_confirmation, '
      'position stays as reported', () {
    final events = [
      _event(id: 'e1', type: EventType.play, fileHash: 'f1', offsetMs: 0, pt: 1000),
      // f-unknown is not in the manifest, e.g. a pending/needs_review
      // reorder the app has not confirmed yet.
      _event(id: 'e2', type: EventType.seek, fileHash: 'f-unknown', offsetMs: 5000, pt: 2000),
    ];

    final state = resolve(events, manifest);

    expect(state.needsConfirmation, isTrue);
    expect(state.position, Position(fileHash: 'f-unknown', offsetMs: 5000));
    expect(state.globalMs, isNull);
  });

  test('last_awake file_hash missing from the manifest also sets '
      'needs_confirmation, even when the final position is known', () {
    final events = [
      _event(id: 'e1', type: EventType.play, fileHash: 'f-unknown', offsetMs: 0, pt: 1000),
      // HEARTBEAT is never awake-proof, so it does not overwrite last_awake;
      // last_awake stays at e1's (unknown) file_hash.
      _event(id: 'e2', type: EventType.heartbeat, fileHash: 'f1', offsetMs: 1000, pt: 2000),
    ];

    final state = resolve(events, manifest);

    expect(state.needsConfirmation, isTrue);
    expect(state.position, Position(fileHash: 'f1', offsetMs: 1000));
    expect(state.globalMs, 1000);
    expect(state.lastAwake, Position(fileHash: 'f-unknown', offsetMs: 0));
  });

  test('all file_hash values known: needs_confirmation is false', () {
    final events = [
      _event(id: 'e1', type: EventType.play, fileHash: 'f1', offsetMs: 0, pt: 1000),
    ];

    final state = resolve(events, manifest);

    expect(state.needsConfirmation, isFalse);
    expect(state.globalMs, 0);
  });
}
