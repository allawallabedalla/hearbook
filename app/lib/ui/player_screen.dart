import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/handler.dart';
import '../audio/playback_status.dart';
import '../domain/manifest.dart';
import '../domain/pause_index.dart';
import '../domain/position.dart';
import '../domain/resolver.dart' show BookState;
import '../l10n/strings.dart';
import '../signals/sleep_timer.dart';
import 'cover.dart';
import 'details_sheet.dart';
import 'faden_screen.dart';
import 'format.dart';
import 'library_screen.dart';
import 'providers.dart';
import 'routes.dart';
import 'theme.dart';
import 'thread_progress.dart';

/// docs/KONZEPT.md "Screens": "1. Start ist der Player: Cover, Titel,
/// Kapitel, Restzeit, der Faden als Buchfortschritt, großer Button." Also
/// the night view's player layout (docs/KONZEPT.md "Nachtmodus": black,
/// cover dimmed, title and chapter dimmed; switched by the display
/// brightness, [nightModeProvider], decision E54).
///
/// Decision E60: a route on top of the library ([PlayerRoute]); the down
/// chevron and the details sheet's "Bibliothek" close it ([closePlayer]),
/// a drag down moves it with the finger and closes it on release (E63).
/// What must outlive it lives app-wide: the sleep timer
/// ([sleepTimerProvider], set from the moon button here or the details
/// sheet), the SLEEP_HINT hook ([nightWindowHookProvider]) and the undo
/// and error SnackBars (ui/playback_announcer.dart).
class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({super.key});

  /// Name of the player's route.
  static const routeName = '/player';

  /// The one route the player is ever shown in. Always use this (through
  /// [showPlayerScreen]) so there is never a second player. [instant]
  /// skips the slide-up (app start, where it covers the library at once).
  static Route<void> route({bool instant = false}) => PlayerRoute(
    settings: const RouteSettings(name: routeName),
    instant: instant,
    builder: (_) => const PlayerScreen(),
  );

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  late final FadenAudioHandler _handler;

  /// What the sheets need to look and act like the player (E46); updated
  /// after every build that changes it.
  ValueNotifier<PlayerChrome>? _chrome;

  @override
  void initState() {
    super.initState();
    _handler = ref.read(audioHandlerProvider);
  }

  @override
  void dispose() {
    _chrome?.dispose();
    super.dispose();
  }

  /// docs/ARCHITEKTUR.md section 9: "AWAKE entsteht bei Berührung des
  /// Player-Screens". Fired on every touch (rate-limited to at most 1 per
  /// 10s inside audio/handler.dart's `awake()`, so this is cheap to call
  /// unconditionally).
  void _onInteraction() => unawaited(_handler.awake());

  /// Back to the library below (E60); the player slides down.
  void _close() => closePlayer(context);

  /// The route following the running drag down (E63); null when no drag
  /// runs, or when it does not follow the finger (reduced motion, nothing
  /// below the player) -- then only [_dragPx] counts, on release.
  PlayerRoute? _dragRoute;

  /// Net distance of the running vertical drag, px (positive: down).
  double _dragPx = 0;

  double get _screenHeight => MediaQuery.sizeOf(context).height;

  void _onDragStart(DragStartDetails details) {
    _dragPx = 0;
    final route = ModalRoute.of(context);
    _dragRoute = route is PlayerRoute &&
            !reduceMotion(context) &&
            route.startDismissDrag()
        ? route
        : null;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final delta = details.primaryDelta ?? 0;
    _dragPx += delta;
    _dragRoute?.updateDismissDrag(delta, _screenHeight);
  }

  /// Up: the details sheet. Down: the route finishes the slide or springs
  /// back (E63); without a following route (reduced motion), it closes at
  /// once past the same threshold.
  void _onDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final route = _dragRoute;
    _dragRoute = null;
    final height = _screenHeight;
    if (_dragPx <= 0 && velocity < -200) {
      route?.endDismissDrag(0, height);
      _openDetails();
      return;
    }
    if (route != null) {
      route.endDismissDrag(velocity, height);
    } else if (playerDragCloses(
      draggedPx: _dragPx,
      velocity: velocity,
      height: height,
    )) {
      _close();
    }
  }

  /// A drag taken away (another gesture won): back into place.
  void _onDragCancel() {
    final route = _dragRoute;
    _dragRoute = null;
    route?.endDismissDrag(-playerCloseFlingVelocity, _screenHeight);
  }

  void _openDetails() {
    final chrome = _chrome;
    if (chrome == null) return;
    unawaited(
      showDetailsSheet(
        context,
        chrome: chrome,
        sleepTimer: ref.read(sleepTimerProvider),
        hooks: DetailsSheetHooks(
          onInteraction: _onInteraction,
          onOpenLibrary: _close,
        ),
      ),
    );
  }

  /// The moon button's choice (E61): the same timer as the details sheet.
  void _openSleepTimer() {
    final chrome = _chrome;
    if (chrome == null) return;
    unawaited(
      showSleepTimerSheet(
        context,
        chrome: chrome,
        sleepTimer: ref.read(sleepTimerProvider),
        onChosen: (minutes) => unawaited(ref.read(sleepTimerDefaultProvider.notifier).set(minutes)),
        hooks: DetailsSheetHooks(onInteraction: _onInteraction),
      ),
    );
  }

  /// docs/KONZEPT.md "Faden aufnehmen": the main button opens the full-screen
  /// Faden-Modus (ui/faden_screen.dart) once `sleep_suspected` is true.
  /// Silently declines (no crash, no navigation) if the book has no
  /// playlist loaded yet (offline/no server -- rare, but Faden-Suche needs
  /// real audio to probe) or the window can't be computed, which per
  /// domain/resolver.dart rule 5 should not happen whenever
  /// `sleep_suspected` is actually true (see docs/ARCHITEKTUR.md section
  /// 13 for this belt-and-braces guard).
  Future<void> _openFadenMode(
    PlayerSessionController session,
    BookState bookState,
  ) async {
    final manifest = session.manifest;
    final sources = session.playlistSources;
    if (manifest == null || sources == null) return;
    final lo = manifest.globalMsFor(bookState.lastAwake);
    var hi = manifest.globalMsFor(bookState.stop);
    if (lo == null || hi == null || hi <= lo) return;
    final stopMs = hi;
    final pausen = globalPauseOffsets(manifest, session.pauseIndex);

    // docs/ARCHITEKTUR.md section 9 / M6: shrink `hi` and/or supply a
    // `prior` first guess from a local sleep-onset reading, if the user
    // opted in and a reading is actually available -- a no-op (adjustment
    // == null) reproduces M5 exactly (`hi` from `stop`, `prior: null`).
    // `lo` itself is never touched here (invariant 9): only ever the
    // Resolver-derived value above is passed on.
    final optedIn = await ref.read(settingsStoreProvider).healthDataOptIn();
    final adjustment = await session.sleepOnsetAdjustment(
      dataSource: ref.read(sleepDataSourceProvider),
      optedIn: optedIn,
      lo: lo,
      hi: hi,
    );
    int? prior;
    if (adjustment != null) {
      hi = adjustment.hi;
      prior = adjustment.prior;
    }
    if (!mounted) return;

    // `hi` is reassigned above, so it is not promoted from `int?` to `int`
    // inside the closure below (a local variable assigned anywhere in this
    // function loses promotion in a closure literal) -- a final copy fixes
    // that without changing anything about the value itself.
    final resolvedHi = hi;
    // Undo hints wait until the Faden screen closes (playback_announcer.dart).
    final fadenOpen = ref.read(fadenScreenOpenProvider.notifier)..set(true);
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => FadenScreen(
            manifest: manifest,
            lo: lo,
            hi: resolvedHi,
            stop: stopMs,
            pausen: pausen,
            prior: prior,
            playlistSources: sources,
          ),
        ),
      );
    } finally {
      fadenOpen.set(false);
    }
  }

  /// Hands the current look to open sheets (E46) -- after the frame,
  /// since they rebuild widgets outside this one.
  void _publish(PlayerChrome chrome) {
    final notifier = _chrome;
    if (notifier == null) {
      _chrome = ValueNotifier(chrome);
    } else if (notifier.value != chrome) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) notifier.value = chrome;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(playerSessionProvider);
    // App-wide since E60 (main.dart watches them too); watched here so the
    // player never runs without them.
    ref.watch(nightWindowHookProvider);
    final sleepTimer = ref.watch(sleepTimerProvider);
    final night = ref.watch(nightModeProvider);
    // Decision E28: the night view always gets the night look; otherwise
    // the "Erscheinungsbild" setting decides. Only [night] drives the night
    // layout below (cover hidden, title and chapter dimmed, ring button) --
    // "Dunkel" shares the night colours, not that layout.
    final tokens = resolveFadenTokens(
      appearance: ref.watch(appearanceProvider),
      platformBrightness: MediaQuery.platformBrightnessOf(context),
      nightMode: night,
    );
    final theme = fadenThemeFor(tokens);
    _publish(PlayerChrome(theme: theme, night: night));

    if (!session.isOpen ||
        session.manifest == null ||
        session.bookState == null) {
      // Opening the book: an empty screen in the right colour, no spinner
      // (it takes a moment at most).
      return Theme(
        data: theme,
        child: Scaffold(backgroundColor: tokens.grund),
      );
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      // The night player has no app bar to set the status bar: light
      // icons on black, dark icons by day.
      value: tokens.isDark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
      child: Theme(
        data: theme,
        // Every touch is an AWAKE; a Listener stays out of the gesture
        // arena, so it never competes with a button or the drag below.
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => _onInteraction(),
          // The whole route, app bar included, follows a drag down (E63);
          // up opens the details. Not on the thread and the scrubber
          // ([NoDismissDrag] in PlayerBody).
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            dragStartBehavior: DragStartBehavior.down,
            onVerticalDragStart: _onDragStart,
            onVerticalDragUpdate: _onDragUpdate,
            onVerticalDragEnd: _onDragEnd,
            onVerticalDragCancel: _onDragCancel,
            child: Scaffold(
              backgroundColor: tokens.grund,
              appBar: night
                  ? null
                  : AppBar(
                      automaticallyImplyLeading: false,
                      leading: IconButton(
                        tooltip: AppStrings.playerClose,
                        icon: const Icon(Icons.keyboard_arrow_down, size: 32),
                        onPressed: _close,
                      ),
                    ),
              body: SafeArea(
                // The type scale stays readable up to 1.6x; beyond that the
                // player would have to drop the controls (decision E44).
                child: MediaQuery.withClampedTextScaling(
                  maxScaleFactor: 1.6,
                  child: PlayerBody(
                    tokens: tokens,
                    night: night,
                    // KONZEPT.md "Nachtmodus": only headphone buttons extend the
                    // sleep timer in its last minute; screen buttons act normally.
                    onMainButton: () {
                      final bookState = session.bookState;
                      if (bookState != null && bookState.sleepSuspected) {
                        unawaited(_openFadenMode(session, bookState));
                        return;
                      }
                      unawaited(_handler.playPause());
                    },
                    onSeek: (delta) => unawaited(_handler.seekBySeconds(delta)),
                    onResumeFromStop: () {
                      final manifest = session.manifest;
                      final bookState = session.bookState;
                      if (manifest == null || bookState == null) return;
                      final idx = manifest.indexOf(bookState.stop.fileHash);
                      unawaited(
                        _handler.resumeFromStop(
                          bookState.stop,
                          fileIndex: idx < 0 ? null : idx,
                        ),
                      );
                    },
                    onOpenDetails: _openDetails,
                    sleepTimerButton: SleepTimerButton(
                      controller: sleepTimer,
                      tokens: tokens,
                      onPressed: _openSleepTimer,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The player's content. Nothing here listens to the position stream
/// itself (decision E44): only the thread and the two small position
/// texts below do, so cover, title and buttons are not rebuilt five
/// times a second.
class PlayerBody extends ConsumerWidget {
  final FadenTokens tokens;
  final bool night;
  final VoidCallback onMainButton;
  final void Function(int deltaSeconds) onSeek;
  final VoidCallback onResumeFromStop;
  final VoidCallback onOpenDetails;

  /// The sleep timer's button (E61), at the right end of the bottom strip
  /// beside the details grip, day and night: the night view has no app
  /// bar, and there it costs no height on a short screen.
  final Widget? sleepTimerButton;

  const PlayerBody({
    super.key,
    required this.tokens,
    required this.night,
    required this.onMainButton,
    required this.onSeek,
    required this.onResumeFromStop,
    required this.onOpenDetails,
    this.sleepTimerButton,
  });

  /// Smallest cover worth showing; below this (tiny screen, huge text)
  /// the cover gives way to the text and controls.
  static const double minCover = 72;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(playerSessionProvider);
    final manifest = session.manifest!;
    final bookState = session.bookState!;
    final handler = ref.watch(audioHandlerProvider);
    final initial = livePosition(handler, session);

    // Swipes up (details) and down (close, E63) are handled around this,
    // by the PlayerScreen, for the whole route.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final coverMax = math.min(
            constraints.maxWidth,
            constraints.maxHeight * 0.38,
          );
          // Short screen with large text: tighter gaps so every control fits.
          final gap = constraints.maxHeight < 640 ? 0.5 : 1.0;
          return Column(
            children: [
              if (night) ...[
                Expanded(
                  child: _NightBookInfo(
                    session: session,
                    manifest: manifest,
                    handler: handler,
                    initial: initial,
                    tokens: tokens,
                    coverSize: math.min(coverMax * 0.6, 180).floorToDouble(),
                  ),
                ),
              ] else
                Expanded(
                  child: _BookInfo(
                    session: session,
                    manifest: manifest,
                    handler: handler,
                    initial: initial,
                    tokens: tokens,
                    coverMax: coverMax,
                  ),
                ),
              SizedBox(height: 24 * gap),
              // A drag down never starts on the thread or the scrubber:
              // they are horizontal (E63).
              NoDismissDrag(
                child: Column(
                  children: [
                    PlayerThread(
                      manifest: manifest,
                      handler: handler,
                      initial: initial,
                      tokens: tokens,
                    ),
                    SizedBox(height: 12 * gap),
                    // Per the user (E59): scrubbing belongs on the player
                    // too, not only in the details sheet. Journaled seek
                    // with undo.
                    ChapterScrubber(
                      manifest: manifest,
                      handler: handler,
                      initial: initial,
                    ),
                  ],
                ),
              ),
              SizedBox(height: 16 * gap),
              StreamBuilder<PlaybackStatus>(
                stream: handler.statusStream,
                initialData: handler.status,
                builder: (context, snap) {
                  final status = snap.data ?? handler.status;
                  return Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _SeekButton(
                        icon: Icons.replay_30,
                        label: AppStrings.seekBackAction,
                        tokens: tokens,
                        night: night,
                        onPressed: () => onSeek(-30),
                      ),
                      const SizedBox(width: 24),
                      PlayerMainButton(
                        tokens: tokens,
                        night: night,
                        playing: status.playing,
                        buffering: status.buffering,
                        sleepSuspected: bookState.sleepSuspected,
                        onPressed: onMainButton,
                      ),
                      const SizedBox(width: 24),
                      _SeekButton(
                        icon: Icons.forward_30,
                        label: AppStrings.seekForwardAction,
                        tokens: tokens,
                        night: night,
                        onPressed: () => onSeek(30),
                      ),
                    ],
                  );
                },
              ),
              // docs/KONZEPT.md "Faden aufnehmen": "Der Hauptbutton heißt
              // jetzt 'Faden aufnehmen', darunter klein 'Ab Stopp
              // weiterhören'."
              if (bookState.sleepSuspected) ...[
                const SizedBox(height: 8),
                Text(
                  AppStrings.mainButtonRecordThread,
                  style: TextStyle(
                    fontSize: FadenTypeSizes.body,
                    color: tokens.tinte,
                  ),
                ),
                TextButton(
                  onPressed: onResumeFromStop,
                  style: TextButton.styleFrom(
                    foregroundColor: tokens.faden,
                    textStyle: const TextStyle(
                      fontSize: FadenTypeSizes.caption,
                    ),
                  ),
                  child: Text(AppStrings.resumeFromStop),
                ),
              ],
              if (night) const Spacer() else const SizedBox(height: 8),
              _BottomStrip(
                handle: _DetailsHandle(tokens: tokens, onTap: onOpenDetails),
                sleepTimerButton: sleepTimerButton,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A drag down to close the player never starts on [child] (E63): a
/// vertical drag here is claimed and dropped, so it does not reach the
/// player's own drag. Horizontal drags and taps reach [child] as usual.
class NoDismissDrag extends StatelessWidget {
  final Widget child;

  const NoDismissDrag({super.key, required this.child});

  @override
  Widget build(BuildContext context) =>
      GestureDetector(onVerticalDragStart: (_) {}, child: child);
}

/// Cover, title, author, chapter and remaining time (day look only).
class _BookInfo extends StatelessWidget {
  final PlayerSessionController session;
  final Manifest manifest;
  final FadenAudioHandler handler;
  final Position initial;
  final FadenTokens tokens;
  final double coverMax;

  const _BookInfo({
    required this.session,
    required this.manifest,
    required this.handler,
    required this.initial,
    required this.tokens,
    required this.coverMax,
  });

  @override
  Widget build(BuildContext context) {
    final title = session.bookTitle ?? '';
    final author = session.bookAuthor?.trim();
    final secondary = TextStyle(
      fontSize: FadenTypeSizes.body,
      color: tokens.tinteLeise,
    );
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Flexible(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = [
                coverMax,
                constraints.maxWidth,
                constraints.maxHeight - 20,
              ].reduce(math.min).floorToDouble();
              if (size < PlayerBody.minCover) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: BookCover(
                  bookId: session.bookId!,
                  title: title,
                  size: size,
                  radius: 12,
                ),
              );
            },
          ),
        ),
        Text(
          title,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: FadenTypeSizes.display,
            color: tokens.tinte,
            height: 1.15,
          ),
        ),
        if (author != null && author.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              author,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: secondary,
            ),
          ),
        const SizedBox(height: 8),
        // The chapter line lives on the chapter scrubber below (E59).
        PositionText(
          handler: handler,
          initial: initial,
          text: (pos) => AppStrings.remainingTime(
            formatRemaining(remainingMsAt(manifest, pos)),
          ),
          style: TextStyle(
            fontSize: FadenTypeSizes.caption,
            color: tokens.tinteLeise,
          ),
        ),
      ],
    );
  }
}

/// The night view's only book info (docs/KONZEPT.md "Nachtmodus", E54):
/// title and current chapter, small and in `tinte-leise`, no cover, no
/// author, no remaining time.
class _NightBookInfo extends StatelessWidget {
  final PlayerSessionController session;
  final Manifest manifest;
  final FadenAudioHandler handler;
  final Position initial;
  final FadenTokens tokens;

  const _NightBookInfo({
    required this.session,
    required this.manifest,
    required this.handler,
    required this.initial,
    required this.tokens,
    required this.coverSize,
  });

  final double coverSize;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Flexible(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = math
                  .min(coverSize, constraints.maxHeight - 16)
                  .floorToDouble();
              if (size < PlayerBody.minCover) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                // Dimmed so it doesn't light up a dark bedroom (E59).
                child: Opacity(
                  opacity: 0.45,
                  child: BookCover(
                    bookId: session.bookId!,
                    title: session.bookTitle ?? '',
                    size: size,
                    radius: 12,
                  ),
                ),
              );
            },
          ),
        ),
        Text(
          session.bookTitle ?? '',
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: FadenTypeSizes.body,
            color: tokens.tinteLeise,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 4),
        PositionText(
          handler: handler,
          initial: initial,
          text: (pos) {
            final idx = manifest.indexOf(pos.fileHash);
            return idx < 0
                ? ''
                : manifest.files[idx].displayTitle(
                    AppStrings.chapterLabel(idx + 1),
                  );
          },
          style: TextStyle(
            fontSize: FadenTypeSizes.caption,
            color: tokens.tinteLeise,
          ),
        ),
      ],
    );
  }
}

/// Book time left from [pos] (0 if the position is not in [manifest]).
int remainingMsAt(Manifest manifest, Position pos) {
  final total = manifest.totalDurationMs;
  final g = manifest.globalMsFor(pos);
  if (g == null) return total;
  return (total - g).clamp(0, total);
}

/// A one-line text derived from the playback position that rebuilds only
/// when its text actually changes (the remaining time: once a minute).
class PositionText extends StatefulWidget {
  final FadenAudioHandler handler;
  final Position initial;
  final String Function(Position position) text;
  final TextStyle style;
  final TextAlign textAlign;

  const PositionText({
    super.key,
    required this.handler,
    required this.initial,
    required this.text,
    required this.style,
    this.textAlign = TextAlign.center,
  });

  @override
  State<PositionText> createState() => _PositionTextState();
}

class _PositionTextState extends State<PositionText> {
  late Position _pos = widget.initial;
  StreamSubscription<Position>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.handler.positionStream.listen((pos) {
      final changed = widget.text(pos) != widget.text(_pos);
      _pos = pos;
      if (changed && mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(PositionText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initial != widget.initial) _pos = widget.initial;
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(
    widget.text(_pos),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    textAlign: widget.textAlign,
    style: widget.style,
  );
}

/// The Faden, the one element that follows the position live. Announces
/// the heard share to screen readers.
class PlayerThread extends StatefulWidget {
  final Manifest manifest;
  final FadenAudioHandler handler;
  final Position initial;
  final FadenTokens tokens;

  const PlayerThread({
    super.key,
    required this.manifest,
    required this.handler,
    required this.initial,
    required this.tokens,
  });

  @override
  State<PlayerThread> createState() => _PlayerThreadState();
}

class _PlayerThreadState extends State<PlayerThread> {
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
  void didUpdateWidget(PlayerThread oldWidget) {
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
    final layout = computeThreadLayout(
      manifest: widget.manifest,
      globalMs: globalMs,
    );
    return Semantics(
      container: true,
      label: AppStrings.threadLabel,
      value: AppStrings.threadValue((layout.heardFraction * 100).floor()),
      child: ThreadProgress(layout: layout, tokens: widget.tokens),
    );
  }
}

class PlayerMainButton extends StatelessWidget {
  final FadenTokens tokens;
  final bool night;
  final bool playing;
  final bool buffering;
  final bool sleepSuspected;
  final VoidCallback? onPressed;

  const PlayerMainButton({
    super.key,
    required this.tokens,
    required this.night,
    required this.playing,
    required this.buffering,
    required this.sleepSuspected,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    // docs/KONZEPT.md "Faden aufnehmen": the button's whole purpose changes
    // once sleep is suspected, so its icon does too (play/pause no longer
    // applies -- the main player is paused throughout Faden-Suche anyway).
    final icon = sleepSuspected
        ? Icons.route
        : (playing ? Icons.pause : Icons.play_arrow);
    final label = sleepSuspected
        ? AppStrings.mainButtonRecordThread
        : (playing ? AppStrings.pauseAction : AppStrings.playAction);
    final foreground = night ? tokens.faden : tokens.grund;
    // E39: waiting for audio shows as a spinner inside the button; the
    // button still pauses.
    final Widget content = buffering && !sleepSuspected
        ? Semantics(
            label: AppStrings.playbackLoading,
            child: SizedBox.square(
              dimension: 32,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: foreground,
              ),
            ),
          )
        : Icon(icon, color: foreground, size: 40);
    return Semantics(
      button: true,
      label: label,
      child: SizedBox.square(
        dimension: fadenMainButtonSize,
        child: night
            // KONZEPT.md "Hauptbutton": "nachts nur ein Ring in faden, damit
            // wenig Licht entsteht" -- no filled background at night.
            ? OutlinedButton(
                onPressed: onPressed,
                style: OutlinedButton.styleFrom(
                  shape: const CircleBorder(),
                  padding: EdgeInsets.zero,
                  side: BorderSide(color: tokens.faden, width: 2),
                ),
                child: content,
              )
            : FilledButton(
                onPressed: onPressed,
                style: FilledButton.styleFrom(
                  shape: const CircleBorder(),
                  padding: EdgeInsets.zero,
                  backgroundColor: tokens.faden,
                  foregroundColor: tokens.grund,
                ),
                child: content,
              ),
      ),
    );
  }
}

class _SeekButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final FadenTokens tokens;
  final bool night;
  final VoidCallback? onPressed;

  const _SeekButton({
    required this.icon,
    required this.label,
    required this.tokens,
    required this.night,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    // No tooltip: the icon's semantic label names the button.
    return SizedBox.square(
      dimension: fadenMinTapTarget,
      child: IconButton(
        icon: Icon(
          icon,
          size: 32,
          color: night ? tokens.faden : tokens.tinte,
          semanticLabel: label,
        ),
        onPressed: onPressed,
      ),
    );
  }
}

/// What the moon button shows while a timer runs (decision E61): the
/// minutes left, rounded up ("12 Min."), or "Kapitelende". Null while no
/// timer runs.
String? sleepTimerButtonText(SleepTimerState state) {
  if (!state.running) return null;
  if (state.mode == SleepTimerMode.chapterEnd) return AppStrings.sleepTimerChapterEnd;
  final minutes = (state.remaining.inSeconds + 59) ~/ 60;
  return AppStrings.sleepTimerMinutes(minutes < 1 ? 1 : minutes);
}

/// The sleep timer on the player itself (decision E61), day and night: a
/// moon, and while a timer runs what is left. Opens the choice
/// ([showSleepTimerSheet]). Follows the shared [SleepTimerController], so
/// it and the details sheet always agree.
class SleepTimerButton extends StatelessWidget {
  final SleepTimerController controller;
  final FadenTokens tokens;
  final VoidCallback onPressed;

  const SleepTimerButton({
    super.key,
    required this.controller,
    required this.tokens,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SleepTimerState>(
      stream: controller.stateStream,
      initialData: controller.state,
      builder: (context, snap) {
        final text = sleepTimerButtonText(snap.data ?? controller.state);
        final color = text == null ? tokens.tinteLeise : tokens.faden;
        return Semantics(
          button: true,
          label: AppStrings.detailsSleepTimer,
          value: text,
          excludeSemantics: true,
          child: TextButton(
            onPressed: onPressed,
            style: TextButton.styleFrom(
              foregroundColor: color,
              minimumSize: const Size.square(fadenMinTapTarget),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(text == null ? Icons.bedtime_outlined : Icons.bedtime, size: 26, color: color),
                if (text != null) ...[
                  const SizedBox(width: 6),
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        text,
                        maxLines: 1,
                        style: TextStyle(
                          color: color,
                          fontSize: FadenTypeSizes.caption,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The details grip across the full width, with the sleep timer's button
/// at the right end (E61). The button never reaches the centred grip; a
/// long label ("Kapitelende" at large text) scales down instead.
class _BottomStrip extends StatelessWidget {
  final Widget handle;
  final Widget? sleepTimerButton;

  const _BottomStrip({required this.handle, required this.sleepTimerButton});

  /// Width of the grip bar plus some air on either side.
  static const double _gripClearance = 36 + 16;

  @override
  Widget build(BuildContext context) {
    final button = sleepTimerButton;
    if (button == null) return handle;
    return LayoutBuilder(
      builder: (context, constraints) {
        final slot = math.max(fadenMinTapTarget, (constraints.maxWidth - _gripClearance) / 2);
        return Stack(
          children: [
            handle,
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              width: slot,
              child: Align(alignment: Alignment.centerRight, child: button),
            ),
          ],
        );
      },
    );
  }
}

/// A visible grip at the bottom: swipe up or tap for the details sheet.
class _DetailsHandle extends StatelessWidget {
  final FadenTokens tokens;
  final VoidCallback onTap;

  const _DetailsHandle({required this.tokens, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: true,
      label: AppStrings.detailsOpen,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          height: fadenMinTapTarget,
          width: double.infinity,
          child: Center(
            child: Container(
              width: 36,
              height: 5,
              decoration: BoxDecoration(
                color: tokens.tinteLeiseFaden,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows the one player (decisions E29, E60): brings it back to the front
/// if it is on the stack, otherwise pushes it on top of the current screen
/// (the library, or the settings), sliding up (E49). Used by the mini
/// player and by picking a book, so there is never a second player.
void showPlayerScreen(NavigatorState navigator) {
  final existing = PlayerRoute.activeIn(navigator);
  if (existing != null) {
    navigator.popUntil((route) => route == existing);
    return;
  }
  unawaited(navigator.push(PlayerScreen.route()));
}

/// Closes the player (E60): the down chevron, "Bibliothek" in the details
/// sheet, and a swipe down that does not follow the finger (reduced
/// motion; a following one pops through [PlayerRoute], E63). It slides
/// down onto the library below. If nothing is below (should not happen),
/// the library replaces it.
void closePlayer(BuildContext context) {
  final navigator = Navigator.of(context);
  if (navigator.canPop()) {
    navigator.pop();
  } else {
    unawaited(navigator.pushAndRemoveUntil(LibraryScreen.route(), (_) => false));
  }
}
