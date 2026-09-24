import 'dart:developer' as developer;

import 'package:drift/drift.dart';

import '../core/hlc.dart';
import '../domain/event.dart';
import 'api.dart';
import 'db.dart';
import 'journal.dart';

const int _pageSize = 500; // section 6: up to 500 events per push/pull

class PushSummary {
  final int accepted;
  final int duplicates;

  /// `event_id`s the server rejected as invalid. They stay in the local
  /// journal (append-only, invariant 2) but are not pushed again.
  final List<String> rejectedEventIds;

  const PushSummary({
    required this.accepted,
    required this.duplicates,
    this.rejectedEventIds = const [],
  });
}

class SyncSummary {
  final PushSummary pushed;
  final int pulled;

  const SyncSummary({required this.pushed, required this.pulled});
}

/// Sync client, docs/ARCHITEKTUR.md section 6: push local events first,
/// then pull remote ones, paging both directions at [_pageSize]. Triggers
/// (app start, foreground, pause, network change, every 60s during
/// playback) are the caller's job (audio/, signals/, later milestones);
/// this class only implements one `sync()` run.
class SyncClient {
  final AppDatabase db;
  final Journal journal;
  final ApiClient api;

  /// Called with the HLC of every pulled remote event *before* it is
  /// stored locally, so the device clock (audio/handler.dart) applies the
  /// HLC receive rule (docs/ARCHITEKTUR.md section 5) before any local
  /// event could be written after it.
  void Function(Hlc remote)? onRemoteHlc;

  SyncClient({required this.db, required this.journal, required this.api});

  Future<SyncSummary> sync() async {
    final pushed = await _pushAll();
    final pulled = await _pullAll();
    return SyncSummary(pushed: pushed, pulled: pulled);
  }

  /// Pushes every locally unsynced event, [_pageSize] at a time. The
  /// server validates per event: "accepted" and "duplicate" mean it now
  /// durably has the event (`INSERT OR IGNORE` on `event_id`); "rejected"
  /// means it never will, so resending cannot help. All three are done as
  /// far as pushing goes, so the whole batch is marked synced -- otherwise
  /// one invalid event would block every later one forever. Rejected events
  /// stay in the local journal (invariant 2: nothing is ever deleted).
  Future<PushSummary> _pushAll() async {
    var accepted = 0;
    var duplicates = 0;
    final rejectedIds = <String>[];
    while (true) {
      final batch = await journal.unsyncedEvents(limit: _pageSize);
      if (batch.isEmpty) break;

      final result = await api.pushEvents(batch);
      accepted += result.accepted;
      duplicates += result.duplicates;
      for (final r in result.rejected) {
        final id = r.eventId ??
            (r.index >= 0 && r.index < batch.length ? batch[r.index].eventId : '#${r.index}');
        rejectedIds.add(id);
        developer.log('server rejected event $id: ${r.error}', name: 'faden.sync');
      }
      await journal.markSynced(batch.map((e) => e.eventId));

      if (batch.length < _pageSize) break; // that was the last, partial page
    }
    return PushSummary(accepted: accepted, duplicates: duplicates, rejectedEventIds: rejectedIds);
  }

  /// Pulls every remote event after the locally stored cursor, storing
  /// each one and advancing the cursor as pages come in (so a crash
  /// mid-pull loses at most the in-flight page, never already-stored
  /// progress).
  Future<int> _pullAll() async {
    var since = await _readCursor();
    var pulled = 0;
    while (true) {
      final page = await api.pullEvents(since: since, limit: _pageSize);
      for (final raw in page.events) {
        final event = Event.fromJson(raw);
        onRemoteHlc?.call(event.hlc);
        await journal.storeRemote(event);
        pulled++;
        final seq = raw['seq'] as int;
        if (seq > since) since = seq;
      }
      await _writeCursor(since);
      if (!page.hasMore) break;
    }
    return pulled;
  }

  Future<int> _readCursor() async {
    final row =
        await (db.select(db.syncState)..where((t) => t.id.equals(0))).getSingleOrNull();
    return row?.sinceSeq ?? 0;
  }

  Future<void> _writeCursor(int seq) async {
    await db.into(db.syncState).insertOnConflictUpdate(
          SyncStateCompanion.insert(id: const Value(0), sinceSeq: Value(seq)),
        );
  }
}
