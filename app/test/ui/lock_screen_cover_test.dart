import 'dart:io';

import 'package:dio/dio.dart';
import 'package:faden/data/api.dart';
import 'package:faden/ui/providers.dart';
import 'package:flutter_test/flutter_test.dart';

class _Api extends ApiClient {
  _Api(this.result) : super(Dio());

  List<int>? result;
  bool fail = false;

  @override
  Future<List<int>?> cover(String bookId) async {
    if (fail) throw DioException(requestOptions: RequestOptions());
    return result;
  }
}

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('faden_cover_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('saves the cover and returns a file uri', () async {
    final uri = await saveCoverForLockScreen('book-1', _Api([1, 2, 3]), dir);

    expect(uri, isNotNull);
    expect(File.fromUri(uri!).readAsBytesSync(), [1, 2, 3]);
  });

  test('offline falls back to the saved copy', () async {
    final api = _Api([1, 2, 3]);
    await saveCoverForLockScreen('book-1', api, dir);
    api.fail = true;

    final uri = await saveCoverForLockScreen('book-1', api, dir);
    expect(File.fromUri(uri!).readAsBytesSync(), [1, 2, 3]);
  });

  test('no cover and no copy gives null', () async {
    expect(await saveCoverForLockScreen('book-1', _Api(null), dir), isNull);
    expect(await saveCoverForLockScreen('book-1', null, dir), isNull);
  });

  test('book ids that are not plain ids never become paths', () async {
    expect(await saveCoverForLockScreen('../evil', _Api([1]), dir), isNull);
    expect(dir.listSync(recursive: true), isEmpty);
  });
}
