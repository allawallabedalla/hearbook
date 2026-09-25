// Tests data/cellular_downloads.dart (decision E66): which chapter files
// to fetch over mobile data, the size estimate, the once-per-session
// question with "Nicht wieder anzeigen", and the downloader rolling
// forward with playback.

import 'dart:io';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:faden/data/api.dart';
import 'package:faden/data/book_downloads.dart';
import 'package:faden/data/cellular_downloads.dart';
import 'package:faden/data/downloads.dart';
import 'package:faden/domain/audio_hash_bounds.dart';
import 'package:faden/domain/manifest.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _tone(int seed, int length) => Uint8List.fromList(List.generate(length, (i) => (i * seed + 11) % 256));

/// Serves `/api/v1/files/<hash>` from [files] and records each request.
ApiClient _api(Map<String, Uint8List> files, List<String> requested) {
  final dio = Dio(BaseOptions(baseUrl: 'https://faden.example'));
  dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
    final hash = options.path.split('/').last;
    requested.add(hash);
    handler.resolve(Response(
      requestOptions: options..responseType = ResponseType.stream,
      statusCode: 200,
      data: ResponseBody.fromBytes(files[hash]!, 200),
    ));
  }));
  return ApiClient(dio);
}

Manifest _manifest(int n, {bool sizes = true}) => Manifest(manifestId: 'm', files: [
      for (var i = 0; i < n; i++)
        ManifestFile(idx: i, fileHash: 'h$i', durationMs: 30 * 60000, sizeBytes: sizes ? 29000000 : null),
    ]);

void main() {
  group('networkKindOf', () {
    test('Wi-Fi or Ethernet alone is Wi-Fi', () {
      expect(networkKindOf([ConnectivityResult.wifi]), NetworkKind.wifi);
      expect(networkKindOf([ConnectivityResult.wifi, ConnectivityResult.vpn]), NetworkKind.wifi);
      expect(networkKindOf([ConnectivityResult.ethernet]), NetworkKind.wifi);
    });

    test('mobile data, a VPN on its own or Wi-Fi plus mobile count as mobile', () {
      expect(networkKindOf([ConnectivityResult.mobile]), NetworkKind.cellular);
      expect(networkKindOf([ConnectivityResult.mobile, ConnectivityResult.vpn]), NetworkKind.cellular);
      expect(networkKindOf([ConnectivityResult.other]), NetworkKind.cellular);
      expect(networkKindOf([ConnectivityResult.wifi, ConnectivityResult.mobile]), NetworkKind.cellular);
    });

    test('nothing is offline', () {
      expect(networkKindOf([ConnectivityResult.none]), NetworkKind.offline);
      expect(networkKindOf(const []), NetworkKind.offline);
    });
  });

  group('chapterFilesToFetch', () {
    final m = _manifest(5);
    List<String> fetch({
      int current = 2,
      Set<String> local = const {},
      NetworkKind network = NetworkKind.cellular,
      bool enabled = true,
      bool playing = true,
    }) =>
        chapterFilesToFetch(
          manifest: m,
          currentIndex: current,
          localFiles: local,
          network: network,
          enabled: enabled,
          playing: playing,
        );

    test('the current and the next chapter, in order', () {
      expect(fetch(), ['h2', 'h3']);
    });

    test('only what is not on the device, never beyond current + next', () {
      expect(fetch(local: {'h2'}), ['h3']);
      expect(fetch(local: {'h3'}), ['h2']);
      expect(fetch(local: {'h2', 'h3'}), isEmpty, reason: 'does not reach for h4');
    });

    test('rolls forward with playback', () {
      expect(fetch(current: 3, local: {'h2', 'h3'}), ['h4']);
      expect(fetch(current: 4, local: {'h4'}), isEmpty, reason: 'the last chapter has no next');
    });

    test('nothing on Wi-Fi (the normal behaviour), offline, paused or with the setting off', () {
      expect(fetch(network: NetworkKind.wifi), isEmpty);
      expect(fetch(network: NetworkKind.offline), isEmpty);
      expect(fetch(playing: false), isEmpty);
      expect(fetch(enabled: false), isEmpty);
    });

    test('nothing for a position outside the manifest', () {
      expect(fetch(current: -1), isEmpty);
      expect(fetch(current: 5), isEmpty);
    });
  });

  group('CellularEstimate', () {
    test('from the real sizes: per hour and the chapter', () {
      final e = CellularEstimate.of(_manifest(3), 1);
      expect(e.bytesPerHour, 58000000);
      expect(e.chapterNumber, 2);
      expect(e.chapterBytes, 29000000);
      expect(e.approximate, isFalse);
    });

    test('without sizes: 64 kbit/s, approximate', () {
      final e = CellularEstimate.of(_manifest(3, sizes: false), 0);
      expect(e.bytesPerHour, 28800000);
      expect(e.chapterBytes, 14400000, reason: '30 min at 8 kB/s');
      expect(e.approximate, isTrue);
    });
  });

  group('CellularConsent', () {
    late bool stored;
    late CellularConsent consent;
    setUp(() {
      stored = false;
      consent = CellularConsent(hintOff: () async => stored, setHintOff: (off) async => stored = off);
    });

    test('asks until answered', () async {
      expect(await consent.decision(), CellularDecision.ask);
      expect(await consent.decision(), CellularDecision.ask);
    });

    test('"Laden" holds for the rest of the session, without storing anything', () async {
      await consent.accept(dontShowAgain: false);
      expect(await consent.decision(), CellularDecision.allowed);
      expect(stored, isFalse);
      final nextSession = CellularConsent(hintOff: () async => stored, setHintOff: (off) async => stored = off);
      expect(await nextSession.decision(), CellularDecision.ask, reason: 'a new app start asks again');
    });

    test('"Nicht wieder anzeigen" is stored and holds in later sessions', () async {
      await consent.accept(dontShowAgain: true);
      expect(stored, isTrue);
      final nextSession = CellularConsent(hintOff: () async => stored, setHintOff: (off) async => stored = off);
      expect(await nextSession.decision(), CellularDecision.allowed);
    });

    test('"Nicht jetzt" declines for the session and does not ask again', () async {
      consent.decline();
      expect(await consent.decision(), CellularDecision.declined);
      expect(stored, isFalse);
    });
  });

  group('ChapterDownloader', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('faden-cellular'));
    tearDown(() => dir.delete(recursive: true));

    final bytes = [for (var i = 0; i < 4; i++) _tone(3 + 2 * i, 500 + 100 * i)];
    final hashes = [for (final b in bytes) audioHashBytes(b)];
    final manifest = Manifest(manifestId: 'm', files: [
      for (var i = 0; i < 4; i++) ManifestFile(idx: i, fileHash: hashes[i], durationMs: 60000, sizeBytes: bytes[i].length),
    ]);

    late List<String> requested;
    late BookDownloads downloads;
    late bool enabled;
    late List<ConnectivityResult> network;
    late bool hintOff;
    late CellularConsent consent;
    late int current;
    late bool playing;
    late ChapterDownloader downloader;

    setUp(() {
      requested = [];
      downloads = BookDownloads(
        manager: DownloadManager(api: _api({for (var i = 0; i < 4; i++) hashes[i]: bytes[i]}, requested), targetDir: dir),
      );
      enabled = true;
      network = [ConnectivityResult.mobile];
      hintOff = false;
      consent = CellularConsent(hintOff: () async => hintOff, setHintOff: (off) async => hintOff = off);
      current = 1;
      playing = true;
      downloader = ChapterDownloader(
        enabled: () async => enabled,
        connectivity: () async => network,
        serverReachable: () async => true,
        consent: consent,
        downloads: downloads,
        playback: () => ChapterPlayback(bookId: 'book', manifest: manifest, currentIndex: current, playing: playing),
      );
    });

    test('asks first, with the estimate of the chapter to load; nothing loads before the answer', () async {
      await downloader.trigger();
      final prompt = downloader.prompt.value;
      expect(prompt, isNotNull);
      expect(prompt!.bookId, 'book');
      expect(prompt.estimate.chapterNumber, 2);
      expect(prompt.estimate.chapterBytes, bytes[1].length);
      expect(prompt.estimate.approximate, isFalse);
      expect(requested, isEmpty);
    });

    test('"Laden" loads the current and the next chapter, then rolls forward without asking again', () async {
      await downloader.trigger();
      await downloader.answer(load: true);
      await downloader.trigger();
      expect(requested, [hashes[1], hashes[2]]);
      expect(downloads.stateFor('book').status, BookDownloadStatus.partial);

      current = 2;
      await downloader.trigger();
      expect(downloader.prompt.value, isNull, reason: 'once per session');
      expect(requested, [hashes[1], hashes[2], hashes[3]], reason: 'only the new next chapter');

      current = 3;
      await downloader.trigger();
      expect(requested, hasLength(3), reason: 'nothing past the end, nothing twice');
    });

    test('"Nicht jetzt": nothing for the rest of the session, and no second question', () async {
      await downloader.trigger();
      await downloader.answer(load: false);
      current = 2;
      await downloader.trigger();
      expect(downloader.prompt.value, isNull);
      expect(requested, isEmpty);
    });

    test('"Nicht wieder anzeigen" from an earlier session: loads without asking', () async {
      hintOff = true;
      await downloader.trigger();
      expect(downloader.prompt.value, isNull);
      expect(requested, [hashes[1], hashes[2]]);
    });

    test('nothing on Wi-Fi, while paused or with the setting off -- and no question', () async {
      network = [ConnectivityResult.wifi];
      await downloader.trigger();
      network = [ConnectivityResult.mobile];
      playing = false;
      await downloader.trigger();
      playing = true;
      enabled = false;
      await downloader.trigger();
      expect(downloader.prompt.value, isNull);
      expect(requested, isEmpty);
    });

    test('a question that is no longer needed goes away', () async {
      await downloader.trigger();
      expect(downloader.prompt.value, isNotNull);
      network = [ConnectivityResult.wifi];
      await downloader.trigger();
      expect(downloader.prompt.value, isNull);
    });

    test('never deletes what is on the device', () async {
      hintOff = true;
      await downloader.trigger();
      current = 3;
      await downloader.trigger();
      for (final h in hashes.skip(1)) {
        expect(await downloads.manager.isDownloaded(h), isTrue);
      }
    });
  });
}
