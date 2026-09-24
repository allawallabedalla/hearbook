import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'format.dart';
import 'providers.dart';
import 'theme.dart';

/// A book cover at a fixed square [size], decoded at display size
/// (`cacheWidth` from the device pixel ratio) instead of the full image.
/// Without a cover it shows a quiet monogram (decision E44): the title's
/// initials in `faden` on a light veil -- never the title itself, which
/// the player already shows right below.
class BookCover extends ConsumerWidget {
  final String bookId;
  final String title;
  final double size;
  final double radius;

  /// Library rows use [libraryCoverProvider] (saved copy first, disposed
  /// when scrolled away); the player and the mini player [coverProvider].
  final bool thumbnail;

  const BookCover({
    super.key,
    required this.bookId,
    required this.title,
    required this.size,
    this.radius = 8,
    this.thumbnail = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = FadenTokens.of(context);
    final async = ref.watch(thumbnail ? libraryCoverProvider(bookId) : coverProvider(bookId));
    final Uint8List? bytes = async.value;
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 2.0;
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: bytes == null
              ? CoverMonogram(title: title, tokens: tokens, size: size)
              : Image.memory(
                  bytes,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  cacheWidth: (size * dpr).round().clamp(1, 4096),
                  errorBuilder: (_, _, _) => CoverMonogram(title: title, tokens: tokens, size: size),
                ),
        ),
      ),
    );
  }
}

class CoverMonogram extends StatelessWidget {
  final String title;
  final FadenTokens tokens;
  final double size;

  const CoverMonogram({super.key, required this.title, required this.tokens, required this.size});

  @override
  Widget build(BuildContext context) {
    final initials = initialsFor(title);
    return ColoredBox(
      color: tokens.flaeche,
      child: Center(
        child: initials.isEmpty
            ? Icon(Icons.menu_book_outlined, color: tokens.faden, size: size * 0.4)
            : Text(
                initials,
                textScaler: TextScaler.noScaling,
                style: TextStyle(
                  color: tokens.faden,
                  fontSize: size * 0.34,
                  fontWeight: FontWeight.w700,
                  height: 1,
                ),
              ),
      ),
    );
  }
}
