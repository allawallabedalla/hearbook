import 'dart:io';

import 'package:flutter/services.dart';

/// Where downloaded audio lives (decision E35): Application Support, not
/// Documents, so gigabytes of re-downloadable audio never go into the
/// iCloud backup (and are not shown in the Files app).
Directory audioDirIn(Directory appSupportDir) => Directory('${appSupportDir.path}/audio');

/// The location downloads used before E35 (`<Documents>/audio`).
Directory legacyAudioDirIn(Directory documentsDir) => Directory('${documentsDir.path}/audio');

/// Sets iOS's "exclude from backup" flag on [dir] (a small method channel
/// in ios/Runner/AppDelegate.swift). Excluding a directory excludes
/// everything inside it. A no-op elsewhere; never throws.
Future<void> excludeFromBackup(Directory dir, {MethodChannel? channel}) async {
  if (channel == null && !Platform.isIOS) return;
  try {
    await (channel ?? const MethodChannel('de.faden.app/storage'))
        .invokeMethod<bool>('excludeFromBackup', {'path': dir.path});
  } catch (_) {
    // Backup exclusion is a storage nicety; playback never depends on it.
  }
}

/// Moves downloads from [from] (the old Documents location) into [to],
/// keeping file names (`<file_hash>.mp3`, plus any `.ok` markers) so every
/// file stays valid. Unfinished `.part` files are dropped. Files that
/// already exist in [to] win. Safe to call on every start: returns at once
/// when [from] does not exist. Returns the number of files moved.
Future<int> migrateDownloads({required Directory from, required Directory to}) async {
  if (!await from.exists()) return 0;
  await to.create(recursive: true);
  var moved = 0;
  await for (final entity in from.list(followLinks: false)) {
    if (entity is! File) continue;
    final name = entity.uri.pathSegments.last;
    if (name.endsWith('.part')) {
      await _tryDelete(entity);
      continue;
    }
    final target = File('${to.path}/$name');
    if (await target.exists()) {
      await _tryDelete(entity);
      continue;
    }
    try {
      await entity.rename(target.path);
    } on FileSystemException {
      // Different volume: copy, then remove the original.
      await entity.copy(target.path);
      await _tryDelete(entity);
    }
    moved++;
  }
  try {
    if (await from.list().isEmpty) await from.delete();
  } catch (_) {}
  return moved;
}

Future<void> _tryDelete(File f) async {
  try {
    await f.delete();
  } catch (_) {}
}
