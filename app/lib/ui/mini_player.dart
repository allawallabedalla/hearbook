import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/event.dart' show EventSource;
import '../domain/position.dart';
import '../l10n/strings.dart';
import 'player_screen.dart';
import 'providers.dart';
import 'theme.dart';
import 'thread_progress.dart';

/// What the mini player's single button does (decision E29). Pure, so the
/// rule is tested on its own (test/ui/mini_player_test.dart).
enum MiniPlayerAction { play, pause, openPlayer }

/// Playing: pause. Paused with `sleep_suspected`: open the player instead
/// of playing, so the listener gets the "Faden aufnehmen" choice rather
/// than a silent resume from the stop point. Otherwise: play.
MiniPlayerAction miniPlayerAction({required bool playing, required bool sleepSuspected}) {
  if (playing) return MiniPlayerAction.pause;
  if (sleepSuspected) return MiniPlayerAction.openPlayer;
  return MiniPlayerAction.play;
}

/// Persistent bar at the bottom of the library and settings screens while
/// a book is open (decision E29; not on the player or the Faden screen).
/// Meant for `Scaffold.bottomNavigationBar`; renders nothing while no book
/// is open. Tapping the bar returns to the player; the button plays or
/// pauses through the handler's journaled methods (invariant 3).
class MiniPlayer extends ConsumerWidget {
  /// Height of the bar's content, without the progress line and the
  /// bottom safe area.
  static const double barHeight = 64;
  static const double lineThickness = 2;
  static const double coverSize = 48;

  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(playerSessionProvider);
    final bookId = session.bookId;
    final manifest = session.manifest;
    final bookState = session.bookState;
    if (bookId == null || manifest == null || bookState == null) return const SizedBox.shrink();

    final tokens = FadenTokens.of(context);
    final handler = ref.watch(audioHandlerProvider);
    final title = session.bookTitle ?? '';

    void openPlayer() => showPlayerScreen(Navigator.of(context));

    return ColoredBox(
      color: tokens.grund,
      child: SafeArea(
        top: false,
        child: StreamBuilder<Position>(
          stream: handler.positionStream,
          initialData: bookState.position,
          builder: (context, positionSnap) {
            final pos = positionSnap.data ?? bookState.position;
            final globalMs = manifest.globalMsFor(pos) ?? bookState.globalMs ?? 0;
            final heard = computeThreadLayout(manifest: manifest, globalMs: globalMs).heardFraction;
            final remainingMs =
                (manifest.totalDurationMs - globalMs).clamp(0, manifest.totalDurationMs);

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ProgressLine(heardFraction: heard, tokens: tokens),
                Semantics(
                  button: true,
                  label: AppStrings.miniPlayerOpen,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: openPlayer,
                    child: SizedBox(
                      height: barHeight,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 16, right: 4),
                        child: Row(
                          children: [
                            _MiniCover(bookId: bookId, title: title, tokens: tokens),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: tokens.tinte, fontSize: FadenTypeSizes.body),
                                  ),
                                  Text(
                                    AppStrings.remainingTime(formatPlaybackDuration(remainingMs)),
                                    maxLines: 1,
                                    style: TextStyle(
                                      color: tokens.tinteLeise,
                                      fontSize: FadenTypeSizes.caption,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            StreamBuilder<bool>(
                              stream: handler.playingStream,
                              initialData: handler.playing,
                              builder: (context, playingSnap) => _PlayPauseButton(
                                action: miniPlayerAction(
                                  playing: playingSnap.data ?? false,
                                  sleepSuspected: bookState.sleepSuspected,
                                ),
                                tokens: tokens,
                                onOpenPlayer: openPlayer,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _PlayPauseButton extends ConsumerWidget {
  final MiniPlayerAction action;
  final FadenTokens tokens;
  final VoidCallback onOpenPlayer;

  const _PlayPauseButton({required this.action, required this.tokens, required this.onOpenPlayer});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (icon, label) = switch (action) {
      MiniPlayerAction.pause => (Icons.pause, AppStrings.pauseAction),
      MiniPlayerAction.play => (Icons.play_arrow, AppStrings.playAction),
      // Same icon as the player's main button once sleep is suspected.
      MiniPlayerAction.openPlayer => (Icons.route, AppStrings.mainButtonRecordThread),
    };
    return SizedBox(
      width: fadenMinTapTarget,
      height: fadenMinTapTarget,
      child: IconButton(
        icon: Icon(icon, color: tokens.faden, size: 32, semanticLabel: label),
        onPressed: () {
          final handler = ref.read(audioHandlerProvider);
          switch (action) {
            case MiniPlayerAction.pause:
              unawaited(handler.pauseFrom(EventSource.ui));
            case MiniPlayerAction.play:
              unawaited(handler.playFrom(EventSource.ui));
            case MiniPlayerAction.openPlayer:
              onOpenPlayer();
          }
        },
      ),
    );
  }
}

/// The book's progress as a thin line along the bar's top edge, in the
/// Faden colours (docs/KONZEPT.md "Design": heard part in `faden`, the rest
/// in `tinte-leise` at 40 %). Not draggable, no knot, no chapter gaps.
class _ProgressLine extends StatelessWidget {
  final double heardFraction;
  final FadenTokens tokens;

  const _ProgressLine({required this.heardFraction, required this.tokens});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MiniPlayer.lineThickness,
      width: double.infinity,
      child: ColoredBox(
        color: tokens.tinteLeiseFaden,
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: heardFraction,
          child: ColoredBox(color: tokens.faden),
        ),
      ),
    );
  }
}

class _MiniCover extends ConsumerWidget {
  final String bookId;
  final String title;
  final FadenTokens tokens;

  const _MiniCover({required this.bookId, required this.title, required this.tokens});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref.watch(coverProvider(bookId)).when(
          data: (b) => b,
          loading: () => null,
          error: (_, _) => null,
        );
    return SizedBox(
      width: MiniPlayer.coverSize,
      height: MiniPlayer.coverSize,
      child: bytes == null
          // docs/KONZEPT.md "Design": "Kein Cover vorhanden: Titel in tinte
          // auf grund, gesetzt in der Hausschrift" -- the player's
          // placeholder style, scaled down.
          ? DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: tokens.tinteLeise),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Text(
                    title,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: tokens.tinte, fontSize: FadenTypeSizes.caption),
                  ),
                ),
              ),
            )
          : ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
            ),
    );
  }
}
