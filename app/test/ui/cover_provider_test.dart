import 'package:dio/dio.dart';
import 'package:faden/data/api.dart';
import 'package:faden/ui/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _CountingApi extends ApiClient {
  _CountingApi() : super(Dio());

  int calls = 0;

  @override
  Future<List<int>?> cover(String bookId) async {
    calls++;
    return [1, 2, 3];
  }
}

void main() {
  test('cover is fetched once per book, not on every rebuild', () async {
    final api = _CountingApi();
    final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(api)]);
    addTearDown(container.dispose);

    final first = await container.read(coverProvider('book-1').future);
    final second = await container.read(coverProvider('book-1').future);

    expect(api.calls, 1);
    expect(identical(first, second), isTrue);
  });

  test('each book has its own cover', () async {
    final api = _CountingApi();
    final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(api)]);
    addTearDown(container.dispose);

    await container.read(coverProvider('book-1').future);
    await container.read(coverProvider('book-2').future);

    expect(api.calls, 2);
  });
}
