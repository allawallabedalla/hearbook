import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/handler.dart';
import '../audio/playback_status.dart';
import '../domain/event.dart' show EventSource;
import '../domain/manifest.dart';
import '../domain/position.dart';
import '../l10n/strings.dart';
import 'cover.dart';
import 'details_sheet.dart' show livePosition;
import 'format.dart';
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
/// pauses through the handler's journaled methods (invariant 3). Only the
/// progress line and the remaining time follow the position (E44).
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
    final initial = livePosition(handler, session);

    void openPlayer() => showPlayerScreen(Navigator.of(context));

    return ColoredBox(
      color: tokens.grund,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ProgressLine(manifest: manifest, handler: handler, initial: initial, tokens: tokens),
            Semantics(
              button: true,
              label: AppStrings.miniPlayerOpen,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: openPlayer,
                // A swipe up on the bar opens the player as well.
                onVerticalDragEnd: (details) {
                  if ((details.primaryVelocity ?? 0) < -200) openPlayer();
                },
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: barHeight),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 16, right: 4),
                    child: Row(
                      children: [
                        BookCover(bookId: bookId, title: title, size: coverSize, radius: 6),
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
                              PositionText(
                                handler: handler,
                                initial: initial,
                                text: (pos) =>
                                    AppStrings.remainingTime(formatRemaining(remainingMsAt(manifest, pos))),
                                style: TextStyle(color: tokens.tinteLeise, fontSize: FadenTypeSizes.caption),
                                textAlign: TextAlign.start,
                              ),
                            ],
                          ),
                        ),
                        StreamBuilder<PlaybackStatus>(
                          stream: handler.statusStream,
                          initialData: handler.status,
                          builder: (context, snap) {
                            final status = snap.data ?? handler.status;
                            return _PlayPauseButton(
                              action: miniPlayerAction(
                                playing: status.playing,
                                sleepSuspected: bookState.sleepSuspected,
                              ),
                              buffering: status.buffering,
                              tokens: tokens,
                              onOpenPlayer: openPlayer,
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlayPauseButton extends ConsumerWidget {
  final MiniPlayerAction action;
  final bool buffering;
  final FadenTokens tokens;
  final VoidCallback onOpenPlayer;

  const _PlayPauseButton({
    required this.action,
    required this.buffering,
    required this.tokens,
    required this.onOpenPlayer,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (icon, label) = switch (action) {
      MiniPlayerAction.pause => (Icons.pause, AppStrings.pauseAction),
      MiniPlayerAction.play => (Icons.play_arrow, AppStrings.playAction),
      // Same icon as the player's main button once sleep is suspected.
      MiniPlayerAction.openPlayer => (Icons.route, AppStrings.mainButtonRecordThread),
    };
    // E39: waiting for audio shows as a spinner inside the button, which
    // still pauses.
    final Widget glyph = buffering && action == MiniPlayerAction.pause
        ? Semantics(
            label: AppStrings.playbackLoading,
            child: SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5, color: tokens.faden),
            ),
          )
        : Icon(icon, color: tokens.faden, size: 32, semanticLabel: label);
    return SizedBox.square(
      dimension: fadenMinTapTarget,
      child: IconButton(
        icon: glyph,
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
class _ProgressLine extends StatefulWidget {
  final Manifest manifest;
  final FadenAudioHandler handler;
  final Position initial;
  final FadenTokens tokens;

  const _ProgressLine({
    required this.manifest,
    required this.handler,
    required this.initial,
    required this.tokens,
  });

  @override
  State<_ProgressLine> createState() => _ProgressLineState();
}

class _ProgressLineState extends State<_ProgressLine> {
  late Position _pos = widget.initial;
  StreamSubscription<Position>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.handler.positionStream.listen((pos) {
      if (mounted) setState(() => _pos = pos);
    });
  }

  @override
  void didUpdateWidget(_ProgressLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initial != widget.initial) _pos = widget.initial;
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final globalMs = widget.manifest.globalMsFor(_pos) ?? 0;
    final heard = computeThreadLayout(manifest: widget.manifest, globalMs: globalMs).heardFraction;
    return SizedBox(
      height: MiniPlayer.lineThickness,
      width: double.infinity,
      child: ColoredBox(
        color: widget.tokens.tinteLeiseFaden,
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: heard,
          child: ColoredBox(color: widget.tokens.faden),
        ),
      ),
    );
  }
}
