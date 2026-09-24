import 'dart:io';

import 'package:faden/data/storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('faden-storage-test'));
  tearDown(() => root.delete(recursive: true));

  group('migrateDownloads (E35)', () {
    test('moves finished downloads and markers from Documents, keeping names and bytes', () async {
      final from = legacyAudioDirIn(Directory(p.join(root.path, 'Documents')));
      final to = audioDirIn(Directory(p.join(root.path, 'Support')));
      await from.create(recursive: true);
      await File(p.join(from.path, 'aaa.mp3')).writeAsBytes([1, 2, 3]);
      await File(p.join(from.path, 'aaa.ok')).writeAsString('3');
      await File(p.join(from.path, 'bbb.mp3.part')).writeAsBytes([9]);

      final moved = await migrateDownloads(from: from, to: to);

      expect(moved, 2);
      expect(await File(p.join(to.path, 'aaa.mp3')).readAsBytes(), [1, 2, 3]);
      expect(await File(p.join(to.path, 'aaa.ok')).readAsString(), '3');
      expect(await File(p.join(to.path, 'bbb.mp3.part')).exists(), isFalse);
      expect(await from.exists(), isFalse);
    });

    test('a file already in the new place wins; nothing to do without the old folder', () async {
      final from = Directory(p.join(root.path, 'old'));
      final to = Directory(p.join(root.path, 'new'));
      await from.create();
      await to.create();
      await File(p.join(from.path, 'aaa.mp3')).writeAsBytes([1]);
      await File(p.join(to.path, 'aaa.mp3')).writeAsBytes([2, 2]);

      expect(await migrateDownloads(from: from, to: to), 0);
      expect(await File(p.join(to.path, 'aaa.mp3')).readAsBytes(), [2, 2]);
      expect(await migrateDownloads(from: from, to: to), 0);
    });
  });

  test('excludeFromBackup asks the platform for the directory and never throws', () async {
    const channel = MethodChannel('test/storage');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (calls.length > 1) throw PlatformException(code: 'failed');
      return true;
    });
    await excludeFromBackup(root, channel: channel);
    await excludeFromBackup(root, channel: channel);
    expect(calls.first.method, 'excludeFromBackup');
    expect(calls.first.arguments, {'path': root.path});
  });
}
