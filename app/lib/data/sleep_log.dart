import '../domain/event.dart';
import '../domain/manifest.dart';
import '../domain/sleep_learning.dart';
import '../domain/sleep_onset.dart';
import 'journal.dart';
import 'settings_store.dart';
import 'sleep_health_writer.dart';

/// "Faden-Suche lernt mit" (decisions E78, E79, E81, E82): keeps the sleep
/// onsets found by Faden searches on this device and, if wanted, writes
/// the night to Apple Health as "Im Bett".
///
/// Local only: the onsets live in the settings table (never an event,
/// never synced) and a Health sample stays in HealthKit on the phone
/// (invariant 7). Every failure is swallowed -- learning must never get
/// in the way of listening.
class SleepLog {
  final SettingsStore settings;
  final Journal journal;
  final SleepHealthWriter? healthWriter;

  SleepLog({required this.settings, required this.journal, this.healthWriter});

  Future<void> _queue = Future.value();

  /// The stored onsets, oldest first.
  Future<List<SleepOnsetRecord>> onsets() async => decodeOnsets(await settings.sleepOnsetsJson());

  /// The first bisection point for a search over `(lo, hi)` learned from
  /// the stored onsets (E78), or null.
  Future<int?> learnedPriorFor({required int lo, required int hi}) async =>
      learnedPrior(lo: lo, hi: hi, onsets: await onsets());

  /// A start from the Faden search's result (its finding, a tapped passage,
  /// "Früher"): [chosenGlobalMs] in the session [sessionId] the listener
  /// fell asleep in, searched from [loGlobalMs] (last awake). A
  /// [recognised] passage becomes the session's onset (replacing an
  /// earlier choice); the fallback to `lo` or a false alarm removes it.
  /// Runs one at a time, in order.
  Future<void> recordChoice({
    required String bookId,
    required String sessionId,
    required Manifest manifest,
    required int loGlobalMs,
    required int chosenGlobalMs,
    required bool recognised,
  }) {
    return _queue = _queue.then((_) async {
      try {
        await _record(
          bookId: bookId,
          sessionId: sessionId,
          manifest: manifest,
          loGlobalMs: loGlobalMs,
          chosenGlobalMs: chosenGlobalMs,
          recognised: recognised,
        );
      } catch (_) {
        // Never in the way of listening.
      }
    });
  }

  Future<void> _record({
    required String bookId,
    required String sessionId,
    required Manifest manifest,
    required int loGlobalMs,
    required int chosenGlobalMs,
    required bool recognised,
  }) async {
    var stored = await onsets();
    final existing = stored.where((o) => o.sessionId == sessionId).firstOrNull;
    if (!recognised) {
      if (existing != null) await _save(removeOnset(stored, sessionId));
      return;
    }

    final session = [
      for (final e in await journal.eventsForBook(bookId))
        if (e.sessionId == sessionId) e,
    ];
    final heartbeats = <HeartbeatSample>[];
    Event? stop;
    for (final e in session) {
      // Probes and touches after the stop may still carry the session id.
      if (e.type != EventType.probe && e.type != EventType.awake) stop = e;
      if (e.type != EventType.heartbeat) continue;
      final g = manifest.globalMsFor(e.position);
      if (g != null) heartbeats.add(HeartbeatSample(wallMs: e.wallMs, globalMs: g));
    }
    if (stop == null) return;
    final onsetWallMs = wallClockAtPosition(heartbeats, chosenGlobalMs);
    if (onsetWallMs == null) return;

    final record = SleepOnsetRecord(
      sessionId: sessionId,
      bookId: bookId,
      onsetWallMs: onsetWallMs,
      tzMin: stop.tzMin,
      listenMs: chosenGlobalMs > loGlobalMs ? chosenGlobalMs - loGlobalMs : 0,
      wakeWallMs: await journal.firstAwakeProofWallMsAfter(stop.wallMs),
      healthWritten: existing?.healthWritten ?? false,
    );
    stored = upsertOnset(stored, record);
    await _save(stored);

    if (!record.healthWritten && await _writeToHealth(record)) {
      await _save(upsertOnset(stored, record.copyWith(healthWritten: true)));
    }
  }

  /// "Im Bett" from the onset to the first awake proof after the stop
  /// (E82): only with the setting on, a plausible interval, write
  /// permission, and no sleep sample for that night yet (a watch or sleep
  /// app knows better; Faden never writes a night twice).
  Future<bool> _writeToHealth(SleepOnsetRecord record) async {
    final writer = healthWriter;
    if (writer == null || !writer.isSupported) return false;
    if (!await settings.healthWriteOptIn()) return false;
    final interval = inBedInterval(record);
    if (interval == null) return false;
    if (!await writer.canWrite()) return false;
    if (await writer.hasSleepOverlapping(startWallMs: interval.start, endWallMs: interval.end)) return false;
    return writer.writeInBed(startWallMs: interval.start, endWallMs: interval.end);
  }

  Future<void> _save(List<SleepOnsetRecord> onsets) => settings.setSleepOnsetsJson(encodeOnsets(onsets));
}
