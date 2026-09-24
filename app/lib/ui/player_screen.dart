import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/undo_hint.dart';
import '../domain/pause_index.dart';
import '../domain/position.dart';
import '../domain/resolver.dart' show BookState;
import '../l10n/strings.dart';
import '../signals/night.dart';
import '../signals/sleep_timer.dart';
import 'details_sheet.dart';
import 'faden_screen.dart';
import 'library_screen.dart';
import 'providers.dart';
import 'theme.dart';
import 'thread_progress.dart';

/// docs/KONZEPT.md "Screens": "1. Start ist der Player: Cover, Titel,
/// Kapitel, Restzeit, der Faden als Buchfortschritt (nicht ziehbar), großer
/// Button." Also owns night mode (docs/KONZEPT.md "Nachtmodus") and the
/// sleep timer (signals/sleep_timer.dart), since both are stated in terms
/// of "the player screen", not a separate route.
class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({super.key});

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  late final ScreenLockController _lock;
  late final SleepTimerController _sleepTimer;
  StreamSubscription<UndoHint>? _undoHintSub;

  /// True while the Faden screen (ui/faden_screen.dart) is pushed on top of
  /// this one. Its RESUME's undo hint arrives then, but must not appear
  /// over the Faden screen (where a tap means "kenne ich"/"close") and
  /// would likely time out before the listener is back here.
  bool _fadenOpen = false;
  UndoHint? _heldUndoHint;
  int _nightStartMin = 20 * 60;
  int _nightEndMin = 6 * 60;

  @override
  void initState() {
    super.initState();
    _lock = ScreenLockController();
    _sleepTimer = SleepTimerController(
      // docs/ARCHITEKTUR.md section 9: "SLEEP_HINT entsteht beim Ablauf des
      // Sleep-Timers" -- M5 adds this on top of M4's plain PAUSE (see
      // decision E13 in docs/ARCHITEKTUR.md section 13).
      onExpire: () => ref.read(audioHandlerProvider).pauseForSleepTimerExpiry(),
      onVolumeChange: (factor) => ref.read(audioHandlerProvider).setSleepFadeVolume(factor),
    );
    _lock.lockedStream.listen((_) => setState(() {}));
    _sleepTimer.stateStream.listen((_) => setState(() {}));
    final handler = ref.read(audioHandlerProvider);
    _undoHintSub = handler.undoHints.listen(_showUndoHint);
    // docs/ARCHITEKTUR.md section 9: a hardware/system media button in the
    // sleep timer's last minute extends it instead of acting, and counts as
    // an awake-proof; a media/system pause while in the night window writes
    // SLEEP_HINT. Both hooks read live state (the closures capture `this`),
    // so no re-wiring is needed as `_sleepTimer`/the night window change.
    handler.onLastMinuteExtend = () => _sleepTimer.extendIfInLastMinute();
    handler.isInNightWindow = () => _inNightWindowNow;
    _loadNightWindow();
  }

  Future<void> _loadNightWindow() async {
    final settings = ref.read(settingsStoreProvider);
    final start = await settings.nightStartMin();
    final end = await settings.nightEndMin();
    if (!mounted) return;
    setState(() {
      _nightStartMin = start;
      _nightEndMin = end;
    });
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
        action: SnackBarAction(
          label: AppStrings.undoAction,
          onPressed: () => ref.read(audioHandlerProvider).undo(hint.target),
        ),
        duration: const Duration(seconds: 8),
      ),
    );
  }

  @override
  void dispose() {
    // The handler outlives this screen (it is a main.dart-owned singleton),
    // so these hooks must not keep referring to a SleepTimerController that
    // is about to be disposed right below.
    final handler = ref.read(audioHandlerProvider);
    handler.onLastMinuteExtend = null;
    handler.isInNightWindow = null;
    _undoHintSub?.cancel();
    _lock.dispose();
    _sleepTimer.dispose();
    super.dispose();
  }

  /// The device-time night window right now (docs/ARCHITEKTUR.md section 9's
  /// "im Nachtfenster" for a media/system pause) -- distinct from [_isNight]
  /// below, which also counts a running sleep timer as "night mode" for the
  /// UI's own dark styling.
  bool get _inNightWindowNow {
    final now = DateTime.now();
    return isInNightWindow(
      nowWallMs: now.millisecondsSinceEpoch,
      tzMin: now.timeZoneOffset.inMinutes,
      nightStartMin: _nightStartMin,
      nightEndMin: _nightEndMin,
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
    unawaited(ref.read(audioHandlerProvider).awake());
  }

  /// Consumes taps during the sleep timer's last minute as an extend
  /// (docs/KONZEPT.md "Nachtmodus") instead of the tapped control's normal
  /// action. Returns true if the tap was consumed this way.
  bool _maybeExtend() => _sleepTimer.extendIfInLastMinute();

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

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(playerSessionProvider);
    final tokens = _isNight ? FadenTokens.night : FadenTokens.day;
    final theme = buildFadenTheme(tokens);

    if (!session.isOpen || session.manifest == null || session.bookState == null) {
      return Theme(
        data: theme,
        child: Scaffold(backgroundColor: tokens.grund, body: const Center(child: CircularProgressIndicator())),
      );
    }

    return Theme(
      data: theme,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _onInteraction,
        onPanDown: (_) => _onInteraction(),
        child: Scaffold(
          backgroundColor: tokens.grund,
          appBar: _isNight
              ? null
              : AppBar(
                  backgroundColor: tokens.grund,
                  elevation: 0,
                  leading: IconButton(
                    icon: Icon(Icons.library_music_outlined, color: tokens.tinte),
                    onPressed: () => Navigator.of(context)
                        .pushReplacement(MaterialPageRoute(builder: (_) => const LibraryScreen())),
                  ),
                ),
          body: SafeArea(
            child: _Body(
              tokens: tokens,
              night: _isNight,
              locked: _lock.locked,
              sleepTimer: _sleepTimer,
              onUnlockHoldStart: _lock.startUnlockHold,
              onUnlockHoldEnd: _lock.cancelUnlockHold,
              onMainButton: () {
                if (_maybeExtend()) return;
                final bookState = session.bookState;
                if (bookState != null && bookState.sleepSuspected) {
                  unawaited(_openFadenMode(session, bookState));
                  return;
                }
                ref.read(audioHandlerProvider).playPause();
              },
              onSeek: (delta) {
                if (_maybeExtend()) return;
                ref.read(audioHandlerProvider).seekBySeconds(delta);
              },
              onResumeFromStop: () {
                final manifest = session.manifest;
                final bookState = session.bookState;
                if (manifest == null || bookState == null) return;
                final idx = manifest.files.indexWhere((f) => f.fileHash == bookState.stop.fileHash);
                ref
                    .read(audioHandlerProvider)
                    .resumeFromStop(bookState.stop, fileIndex: idx < 0 ? null : idx);
              },
              onOpenDetails: () => showDetailsSheet(context, sleepTimer: _sleepTimer),
            ),
          ),
        ),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  final FadenTokens tokens;
  final bool night;
  final bool locked;
  final SleepTimerController sleepTimer;
  final VoidCallback onUnlockHoldStart;
  final VoidCallback onUnlockHoldEnd;
  final VoidCallback onMainButton;
  final void Function(int deltaSeconds) onSeek;
  final VoidCallback onResumeFromStop;
  final VoidCallback onOpenDetails;

  const _Body({
    required this.tokens,
    required this.night,
    required this.locked,
    required this.sleepTimer,
    required this.onUnlockHoldStart,
    required this.onUnlockHoldEnd,
    required this.onMainButton,
    required this.onSeek,
    required this.onResumeFromStop,
    required this.onOpenDetails,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(playerSessionProvider);
    final manifest = session.manifest!;
    final bookState = session.bookState!;
    final handler = ref.watch(audioHandlerProvider);

    return StreamBuilder<Position>(
      stream: handler.positionStream,
      initialData: bookState.position,
      builder: (context, positionSnap) {
        final pos = positionSnap.data ?? bookState.position;
        final globalMs = manifest.globalMsFor(pos) ?? bookState.globalMs ?? 0;
        final layout = computeThreadLayout(manifest: manifest, globalMs: globalMs);
        final chapterIdx = manifest.files.indexWhere((f) => f.fileHash == pos.fileHash);
        final remainingMs = (manifest.totalDurationMs - globalMs).clamp(0, manifest.totalDurationMs);

        return GestureDetector(
          onLongPressStart: locked ? (_) => onUnlockHoldStart() : null,
          onLongPressEnd: locked ? (_) => onUnlockHoldEnd() : null,
          onLongPressCancel: locked ? onUnlockHoldEnd : null,
          onVerticalDragEnd: (details) {
            final velocity = details.primaryVelocity;
            if (velocity != null && velocity < -200) onOpenDetails();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Spacer(),
                if (!night) ...[
                  _Cover(bookId: session.bookId!, tokens: tokens, title: session.bookTitle ?? ''),
                  const SizedBox(height: 24),
                  Text(
                    session.bookTitle ?? '',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: FadenTypeSizes.display, color: tokens.tinte),
                  ),
                  if (chapterIdx >= 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        AppStrings.chapterOfTotal(chapterIdx + 1, manifest.files.length),
                        style: TextStyle(fontSize: FadenTypeSizes.body, color: tokens.tinteLeise),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      AppStrings.remainingTime(_formatDuration(remainingMs)),
                      style: TextStyle(fontSize: FadenTypeSizes.caption, color: tokens.tinteLeise),
                    ),
                  ),
                ],
                const SizedBox(height: 32),
                ThreadProgress(layout: layout, tokens: tokens),
                const SizedBox(height: 32),
                StreamBuilder<bool>(
                  stream: handler.playingStream,
                  initialData: handler.playing,
                  builder: (context, playingSnap) {
                    final playing = playingSnap.data ?? false;
                    return Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _RoundIconButton(
                          icon: Icons.replay_30,
                          tokens: tokens,
                          night: night,
                          onPressed: locked ? null : () => onSeek(-30),
                        ),
                        const SizedBox(width: 24),
                        _MainButton(
                          tokens: tokens,
                          night: night,
                          playing: playing,
                          sleepSuspected: bookState.sleepSuspected,
                          onPressed: locked ? null : onMainButton,
                        ),
                        const SizedBox(width: 24),
                        _RoundIconButton(
                          icon: Icons.forward_30,
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
                  const SizedBox(height: 16),
                  Text(
                    AppStrings.mainButtonRecordThread,
                    style: TextStyle(fontSize: FadenTypeSizes.body, color: tokens.tinte),
                  ),
                  const SizedBox(height: 4),
                  GestureDetector(
                    onTap: locked ? null : onResumeFromStop,
                    child: Text(
                      AppStrings.resumeFromStop,
                      style: TextStyle(fontSize: FadenTypeSizes.caption, color: tokens.tinteLeise),
                    ),
                  ),
                ],
                if (night && locked)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      AppStrings.lockedHint,
                      style: TextStyle(color: tokens.tinteLeise, fontSize: FadenTypeSizes.caption),
                    ),
                  ),
                const Spacer(),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _MainButton extends StatelessWidget {
  final FadenTokens tokens;
  final bool night;
  final bool playing;
  final bool sleepSuspected;
  final VoidCallback? onPressed;

  const _MainButton({
    required this.tokens,
    required this.night,
    required this.playing,
    required this.sleepSuspected,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    // docs/KONZEPT.md "Faden aufnehmen": the button's whole purpose changes
    // once sleep is suspected, so its icon does too (play/pause no longer
    // applies -- the main player is paused throughout Faden-Suche anyway).
    final icon = sleepSuspected ? Icons.route : (playing ? Icons.pause : Icons.play_arrow);
    return SizedBox(
      width: fadenMainButtonSize,
      height: fadenMainButtonSize,
      child: night
          // KONZEPT.md "Hauptbutton": "nachts nur ein Ring in faden, damit
          // wenig Licht entsteht" -- no filled background at night.
          ? OutlinedButton(
              onPressed: onPressed,
              style: OutlinedButton.styleFrom(
                shape: const CircleBorder(),
                side: BorderSide(color: tokens.faden, width: 2),
              ),
              child: Icon(icon, color: tokens.faden, size: 36),
            )
          : ElevatedButton(
              onPressed: onPressed,
              style: ElevatedButton.styleFrom(
                shape: const CircleBorder(),
                backgroundColor: tokens.faden,
                foregroundColor: tokens.grund,
              ),
              child: Icon(icon, color: tokens.grund, size: 36),
            ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  final IconData icon;
  final FadenTokens tokens;
  final bool night;
  final VoidCallback? onPressed;

  const _RoundIconButton({
    required this.icon,
    required this.tokens,
    required this.night,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: fadenMinTapTarget,
      height: fadenMinTapTarget,
      child: IconButton(
        icon: Icon(icon, color: night ? tokens.faden : tokens.tinte),
        onPressed: onPressed,
      ),
    );
  }
}

class _Cover extends ConsumerWidget {
  final String bookId;
  final FadenTokens tokens;
  final String title;

  const _Cover({required this.bookId, required this.tokens, required this.title});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(apiClientProvider);
    return SizedBox(
      width: 220,
      height: 220,
      child: api == null
          ? _placeholder()
          : FutureBuilder<List<int>?>(
              future: api.cover(bookId),
              builder: (context, snap) {
                final bytes = snap.data;
                if (bytes == null) return _placeholder();
                return ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(_asUint8List(bytes), fit: BoxFit.cover),
                );
              },
            ),
    );
  }

  Widget _placeholder() {
    // docs/KONZEPT.md "Design": "Kein Cover vorhanden: Titel in tinte auf
    // grund, gesetzt in der Hausschrift."
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: tokens.tinteLeise),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(color: tokens.tinte, fontSize: FadenTypeSizes.title),
          ),
        ),
      ),
    );
  }
}

Uint8List _asUint8List(List<int> bytes) =>
    bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

String _formatDuration(int ms) {
  final totalSeconds = ms ~/ 1000;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  final mm = minutes.toString().padLeft(hours > 0 ? 2 : 1, '0');
  final ss = seconds.toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
}
