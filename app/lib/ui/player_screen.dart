import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/handler.dart';
import '../audio/playback_status.dart';
import '../audio/undo_hint.dart';
import '../domain/event.dart' show EventSource;
import '../domain/manifest.dart';
import '../domain/pause_index.dart';
import '../domain/position.dart';
import '../domain/resolver.dart' show BookState;
import '../l10n/strings.dart';
import '../signals/night.dart';
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
/// Kapitel, Restzeit, der Faden als Buchfortschritt (nicht ziehbar), großer
/// Button." Also owns night mode (docs/KONZEPT.md "Nachtmodus") and the
/// sleep timer (signals/sleep_timer.dart), since both are stated in terms
/// of "the player screen", not a separate route.
class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({super.key});

  /// Name of the player's route, so [showPlayerScreen] can find it on the
  /// navigator stack.
  static const routeName = '/player';

  /// The one route the player is ever shown in. Always use this so
  /// [showPlayerScreen] recognises it. [instant] skips the slide-up (app
  /// start, where it replaces the empty start screen).
  static Route<void> route({bool instant = false}) => PlayerRoute(
    settings: const RouteSettings(name: routeName),
    instant: instant,
    builder: (_) => const PlayerScreen(),
  );

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  late final ScreenLockController _lock;
  late final SleepTimerController _sleepTimer;
  late final FadenAudioHandler _handler;
  final List<StreamSubscription<Object?>> _subs = [];

  /// What the details sheet needs to look and act like the player (E46);
  /// updated after every build that changes it.
  ValueNotifier<PlayerChrome>? _chrome;

  /// True while the Faden screen (ui/faden_screen.dart) is pushed on top of
  /// this one. Its RESUME's undo hint arrives then, but must not appear
  /// over the Faden screen (where a tap means "kenne ich"/"close") and
  /// would likely time out before the listener is back here.
  bool _fadenOpen = false;
  UndoHint? _heldUndoHint;

  /// The playback error a SnackBar was shown for, so one error is
  /// announced once.
  PlaybackFailure? _shownError;

  @override
  void initState() {
    super.initState();
    _lock = ScreenLockController();
    final handler = _handler = ref.read(audioHandlerProvider);
    _sleepTimer = SleepTimerController(
      // docs/ARCHITEKTUR.md section 9: "SLEEP_HINT entsteht beim Ablauf des
      // Sleep-Timers" -- M5 adds this on top of M4's plain PAUSE (see
      // decision E13 in docs/ARCHITEKTUR.md section 13).
      onExpire: () => handler.pauseForSleepTimerExpiry(),
      onVolumeChange: (factor) => handler.setSleepFadeVolume(factor),
      // E42: counts down only while playing; "Kapitelende" follows the
      // chapter actually playing, at the current speed.
      isPlaying: () => handler.playing,
      chapterRemaining: () => handler.chapterRemaining(),
    );
    _subs.add(
      _lock.lockedStream.listen((locked) {
        // The 1 s hold worked: a light tick, since the screen may be dark.
        if (!locked) unawaited(HapticFeedback.lightImpact());
        if (mounted) setState(() {});
      }),
    );
    _subs.add(
      _sleepTimer.stateStream.listen((_) {
        if (mounted) setState(() {});
      }),
    );
    _subs.add(handler.undoHints.listen(_showUndoHint));
    _subs.add(handler.chapterAdvanced.listen((_) => _sleepTimer.onChapterAdvanced()));
    _subs.add(handler.statusStream.listen(_onStatus));
    // docs/ARCHITEKTUR.md section 9: a hardware/system media button in the
    // sleep timer's last minute extends it instead of acting, and counts as
    // an awake-proof; a media/system pause while in the night window writes
    // SLEEP_HINT. Both hooks read live state (the closures capture `this`),
    // so no re-wiring is needed as `_sleepTimer`/the night window change.
    handler.onLastMinuteExtend = () {
      final extended = _sleepTimer.extendIfInLastMinute();
      if (extended) unawaited(HapticFeedback.lightImpact());
      return extended;
    };
    handler.isInNightWindow = () => _inNightWindowNow;
  }

  void _showUndoHint(UndoHint hint) {
    if (!mounted) return;
    if (_fadenOpen) {
      // Keep the first one: it points back to where playback stood before
      // the search (the pre-sleep position). Later ones only come from
      // "Früher" steps the listener took on the Faden screen itself.
      _heldUndoHint ??= hint;
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(hint.message),
        action: SnackBarAction(label: AppStrings.undoAction, onPressed: () => _handler.undo(hint.target)),
        duration: const Duration(seconds: 8),
      ),
    );
  }

  /// E39: a playback error shows once as "Kann nicht abspielen" with a
  /// retry; the next play reloads the playlist (audio/handler.dart). The
  /// root ScaffoldMessenger shows it on whatever screen is in front.
  void _onStatus(PlaybackStatus status) {
    final error = status.error;
    if (error == null) {
      _shownError = null;
      return;
    }
    if (error == _shownError || !mounted || _fadenOpen) return;
    _shownError = error;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppStrings.playbackError),
        action: SnackBarAction(
          label: AppStrings.libraryRetry,
          onPressed: () => unawaited(_handler.playFrom(EventSource.ui)),
        ),
        duration: const Duration(seconds: 10),
      ),
    );
  }

  @override
  void dispose() {
    // The handler outlives this screen (it is a main.dart-owned singleton),
    // so these hooks must not keep referring to a SleepTimerController that
    // is about to be disposed right below.
    _handler.onLastMinuteExtend = null;
    _handler.isInNightWindow = null;
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _lock.dispose();
    _sleepTimer.dispose();
    _chrome?.dispose();
    super.dispose();
  }

  /// The device-time night window right now (docs/ARCHITEKTUR.md section 9's
  /// "im Nachtfenster" for a media/system pause) -- distinct from [_isNight]
  /// below, which also counts a running sleep timer as "night mode" for the
  /// UI's own dark styling.
  ///
  /// Reads the window from [nightWindowProvider] on every call, so a change
  /// in the settings screen applies at once (the player stays mounted below
  /// the library and settings, see [showPlayerScreen]). Until the setting
  /// has loaded, the default 20:00-06:00 applies, as before.
  bool get _inNightWindowNow {
    final window = ref.read(nightWindowProvider).value ?? NightWindow.defaults;
    final now = DateTime.now();
    return isInNightWindow(
      nowWallMs: now.millisecondsSinceEpoch,
      tzMin: now.timeZoneOffset.inMinutes,
      nightStartMin: window.startMin,
      nightEndMin: window.endMin,
    );
  }

  bool get _isNight =>
      isNightModeActive(inNightWindow: _inNightWindowNow, sleepTimerRunning: _sleepTimer.state.running);

  /// docs/ARCHITEKTUR.md section 9: "AWAKE entsteht bei Berührung des
  /// Player-Screens". Fired on every touch, regardless of lock state
  /// (rate-limited to at most 1 per 10s inside audio/handler.dart's
  /// `awake()`, so this is cheap to call unconditionally).
  void _onInteraction() {
    _lock.onInteraction();
    unawaited(_handler.awake());
  }

  bool get _locked => _isNight && _lock.locked;

  /// Pushed on top (not replacing the player), so the player -- and its
  /// sleep timer -- stays alive below the library and the mini player can
  /// return to it (decision E29). The player slides down to show it (E49).
  void _openLibrary() {
    Navigator.of(context).push(UnderPlayerRoute<void>(builder: (_) => const LibraryScreen()));
  }

  void _openDetails() {
    final chrome = _chrome;
    if (chrome == null || _locked) return;
    unawaited(
      showDetailsSheet(
        context,
        chrome: chrome,
        sleepTimer: _sleepTimer,
        hooks: DetailsSheetHooks(
          onInteraction: _onInteraction,
          onUnlockHoldStart: _lock.startUnlockHold,
          onUnlockHoldEnd: _lock.cancelUnlockHold,
          onOpenLibrary: _openLibrary,
        ),
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
  Future<void> _openFadenMode(PlayerSessionController session, BookState bookState) async {
    final manifest = session.manifest;
    final sources = session.playlistSources;
    if (manifest == null || sources == null) return;
    final lo = manifest.globalMsFor(bookState.lastAwake);
    var hi = manifest.globalMsFor(bookState.stop);
    if (lo == null || hi == null || hi <= lo) return;
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
    _fadenOpen = true;
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => FadenScreen(
            manifest: manifest,
            lo: lo,
            hi: resolvedHi,
            pausen: pausen,
            prior: prior,
            playlistSources: sources,
          ),
        ),
      );
    } finally {
      _fadenOpen = false;
    }
    final held = _heldUndoHint;
    _heldUndoHint = null;
    if (held != null) _showUndoHint(held);
  }

  /// Hands the current look to open sheets and, for the rest of the app,
  /// to [nightModeProvider] (E46) -- after the frame, since both rebuild
  /// widgets outside this one.
  void _publish(PlayerChrome chrome) {
    final notifier = _chrome;
    if (notifier == null) {
      _chrome = ValueNotifier(chrome);
    } else if (notifier.value != chrome) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) notifier.value = chrome;
      });
    }
    if (ref.read(nightModeProvider) != chrome.night) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(nightModeProvider.notifier).set(chrome.night);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(playerSessionProvider);
    // Rebuild when the night window setting loads or changes.
    ref.watch(nightWindowProvider);
    final night = _isNight;
    // Decision E28: Nachtmodus always gets the night look; otherwise the
    // "Erscheinungsbild" setting decides. Only [night] drives the
    // Nachtmodus *behaviour* below (cover hidden, ring button, lock) --
    // "Dunkel" shares the night colours, not that behaviour.
    final tokens = resolveFadenTokens(
      appearance: ref.watch(appearanceProvider),
      platformBrightness: MediaQuery.platformBrightnessOf(context),
      nightMode: night,
    );
    final theme = fadenThemeFor(tokens);
    // docs/KONZEPT.md lists the 10 s button lock under "Nachtmodus" only;
    // the lock controller itself runs all the time, so it is gated here.
    final locked = night && _lock.locked;
    _publish(PlayerChrome(theme: theme, night: night, locked: locked));

    if (!session.isOpen || session.manifest == null || session.bookState == null) {
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
      value: tokens.isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Theme(
        data: theme,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: _onInteraction,
          onPanDown: (_) => _onInteraction(),
          child: Scaffold(
            backgroundColor: tokens.grund,
            appBar: night
                ? null
                : AppBar(
                    automaticallyImplyLeading: false,
                    leading: IconButton(
                      tooltip: AppStrings.libraryTitle,
                      icon: const Icon(Icons.menu_book_outlined),
                      onPressed: _openLibrary,
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
                  locked: locked,
                  onUnlockHoldStart: _lock.startUnlockHold,
                  onUnlockHoldEnd: _lock.cancelUnlockHold,
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
                    unawaited(_handler.resumeFromStop(bookState.stop, fileIndex: idx < 0 ? null : idx));
                  },
                  onOpenDetails: _openDetails,
                  onOpenLibrary: _openLibrary,
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
  final bool locked;
  final VoidCallback onUnlockHoldStart;
  final VoidCallback onUnlockHoldEnd;
  final VoidCallback onMainButton;
  final void Function(int deltaSeconds) onSeek;
  final VoidCallback onResumeFromStop;
  final VoidCallback onOpenDetails;
  final VoidCallback onOpenLibrary;

  const PlayerBody({
    super.key,
    required this.tokens,
    required this.night,
    required this.locked,
    required this.onUnlockHoldStart,
    required this.onUnlockHoldEnd,
    required this.onMainButton,
    required this.onSeek,
    required this.onResumeFromStop,
    required this.onOpenDetails,
    required this.onOpenLibrary,
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

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPressStart: locked ? (_) => onUnlockHoldStart() : null,
      onLongPressEnd: locked ? (_) => onUnlockHoldEnd() : null,
      onLongPressCancel: locked ? onUnlockHoldEnd : null,
      // Up: details. Down: the library (the player slides away, E49).
      // Neither while the night lock is on.
      onVerticalDragEnd: locked
          ? null
          : (details) {
              final velocity = details.primaryVelocity ?? 0;
              if (velocity < -200) onOpenDetails();
              if (velocity > 200) onOpenLibrary();
            },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final coverMax = math.min(constraints.maxWidth, constraints.maxHeight * 0.38);
            return Column(
              children: [
                if (night)
                  const Spacer()
                else
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
                const SizedBox(height: 24),
                PlayerThread(manifest: manifest, handler: handler, initial: initial, tokens: tokens),
                const SizedBox(height: 24),
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
                          onPressed: locked ? null : () => onSeek(-30),
                        ),
                        const SizedBox(width: 24),
                        PlayerMainButton(
                          tokens: tokens,
                          night: night,
                          playing: status.playing,
                          buffering: status.buffering,
                          sleepSuspected: bookState.sleepSuspected,
                          onPressed: locked ? null : onMainButton,
                        ),
                        const SizedBox(width: 24),
                        _SeekButton(
                          icon: Icons.forward_30,
                          label: AppStrings.seekForwardAction,
                          tokens: tokens,
                          night: night,
                          onPressed: locked ? null : () => onSeek(30),
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
                    style: TextStyle(fontSize: FadenTypeSizes.body, color: tokens.tinte),
                  ),
                  TextButton(
                    onPressed: locked ? null : onResumeFromStop,
                    style: TextButton.styleFrom(
                      foregroundColor: tokens.faden,
                      textStyle: const TextStyle(fontSize: FadenTypeSizes.caption),
                    ),
                    child: Text(AppStrings.resumeFromStop),
                  ),
                ],
                if (locked)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      AppStrings.lockedHint,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: tokens.tinteLeise, fontSize: FadenTypeSizes.caption),
                    ),
                  ),
                if (night) const Spacer() else const SizedBox(height: 8),
                _DetailsHandle(tokens: tokens, onTap: locked ? null : onOpenDetails),
              ],
            );
          },
        ),
      ),
    );
  }
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
    final secondary = TextStyle(fontSize: FadenTypeSizes.body, color: tokens.tinteLeise);
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
                child: BookCover(bookId: session.bookId!, title: title, size: size, radius: 12),
              );
            },
          ),
        ),
        Text(
          title,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: FadenTypeSizes.display, color: tokens.tinte, height: 1.15),
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
        PositionText(
          handler: handler,
          initial: initial,
          text: (pos) {
            final idx = manifest.indexOf(pos.fileHash);
            return idx < 0 ? '' : AppStrings.chapterOfTotal(idx + 1, manifest.files.length);
          },
          style: TextStyle(fontSize: FadenTypeSizes.caption, color: tokens.tinteLeise),
        ),
        PositionText(
          handler: handler,
          initial: initial,
          text: (pos) => AppStrings.remainingTime(formatRemaining(remainingMsAt(manifest, pos))),
          style: TextStyle(fontSize: FadenTypeSizes.caption, color: tokens.tinteLeise),
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
    final layout = computeThreadLayout(manifest: widget.manifest, globalMs: globalMs);
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
    final icon = sleepSuspected ? Icons.route : (playing ? Icons.pause : Icons.play_arrow);
    final label = sleepSuspected
        ? AppStrings.mainButtonRecordThread
        : (playing ? AppStrings.pauseAction : AppStrings.playAction);
    final foreground = night ? tokens.faden : tokens.grund;
    // E39: waiting for audio shows as a spinner inside the button; the
    // button still pauses.
    final Widget content = buffering && !sleepSuspected
        ? Semantics(
            label: AppStrings.playbackLoading,
            child: SizedBox.square(dimension: 32, child: CircularProgressIndicator(strokeWidth: 3, color: foreground)),
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
    // No tooltip: its long press would compete with the 1 s unlock hold.
    return SizedBox.square(
      dimension: fadenMinTapTarget,
      child: IconButton(
        icon: Icon(icon, size: 32, color: night ? tokens.faden : tokens.tinte, semanticLabel: label),
        onPressed: onPressed,
      ),
    );
  }
}

/// A visible grip at the bottom: swipe up or tap for the details sheet.
class _DetailsHandle extends StatelessWidget {
  final FadenTokens tokens;
  final VoidCallback? onTap;

  const _DetailsHandle({required this.tokens, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onTap != null,
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
                color: onTap == null ? tokens.tinteLeiseFaden.withValues(alpha: 0.2) : tokens.tinteLeiseFaden,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Brings the player back to the front (decision E29): pops every route
/// above [PlayerScreen.route] if it is on the stack; otherwise (the app
/// started on the library because no book was open yet) replaces the whole
/// stack with it, so there is only ever one player and it is the root
/// route (docs/KONZEPT.md "Start ist der Player"). Either way it slides up
/// (E49).
void showPlayerScreen(NavigatorState navigator) {
  var found = false;
  navigator.popUntil((route) {
    if (route.settings.name == PlayerScreen.routeName) found = true;
    return found || route.isFirst;
  });
  if (!found) navigator.pushAndRemoveUntil(PlayerScreen.route(), (_) => false);
}
