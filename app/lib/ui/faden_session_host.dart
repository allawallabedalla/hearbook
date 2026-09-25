import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/handler.dart';
import '../domain/asleep_prompt.dart';
import '../l10n/strings.dart';
import 'faden_screen.dart';
import 'faden_session.dart';
import 'providers.dart';
import 'theme.dart';

bool get _inForeground {
  final state = WidgetsBinding.instance.lifecycleState;
  return state == null || state == AppLifecycleState.resumed;
}

/// Shows the running Faden search (decision E85): as soon as one starts
/// while the app is in front, and when the app comes back to the front
/// while one runs without its screen (started from the lock screen). Sits
/// above the navigator (main.dart's `MaterialApp.builder`).
class FadenSessionHost extends ConsumerStatefulWidget {
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  const FadenSessionHost({super.key, required this.navigatorKey, required this.child});

  @override
  ConsumerState<FadenSessionHost> createState() => _FadenSessionHostState();
}

class _FadenSessionHostState extends ConsumerState<FadenSessionHost> {
  AppLifecycleListener? _lifecycle;
  FadenSession? _shown;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(_maybeShow()));
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    super.dispose();
  }

  Future<void> _maybeShow() async {
    final session = ref.read(fadenSessionProvider);
    if (!mounted || session == null || session.ended || !_inForeground) return;
    if (identical(session, _shown) || session.screenAttached) return;
    final navigator = widget.navigatorKey.currentState;
    if (navigator == null) return;
    _shown = session;
    // Undo hints wait until the Faden screen closes (playback_announcer.dart).
    final open = ref.read(fadenScreenOpenProvider.notifier)..set(true);
    try {
      await navigator.push(MaterialPageRoute<void>(builder: (_) => FadenScreen.forSession(session)));
    } finally {
      if (mounted) open.set(false);
      if (identical(_shown, session)) _shown = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<FadenSession?>(fadenSessionProvider, (_, next) {
      if (next != null) WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_maybeShow()));
    });
    return widget.child;
  }
}

/// "Eingeschlafen?" (decision E84): the question after a long stretch of
/// listening without any touch. Asked when the app comes back to the
/// front, or at the first touch while it was open -- that touch reaches
/// nothing else (a transparent shield lies over the app while the
/// question is due), so it can neither pause the book nor count as an
/// awake proof before the answer. Not with CarPlay as the output, once per
/// stretch, never during a Faden search (domain/asleep_prompt.dart).
class AsleepPromptHost extends ConsumerStatefulWidget {
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  const AsleepPromptHost({super.key, required this.navigatorKey, required this.child});

  /// How often the question is looked at while the app is in front (the
  /// stretch grows while the book plays).
  static const Duration recheckEvery = Duration(seconds: 30);

  @override
  ConsumerState<AsleepPromptHost> createState() => _AsleepPromptHostState();
}

class _AsleepPromptHostState extends ConsumerState<AsleepPromptHost> {
  AppLifecycleListener? _lifecycle;
  Timer? _timer;
  StreamSubscription<void>? _stretchSub;
  AsleepAsk _due = AsleepAsk.no;
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    final handler = ref.read(audioHandlerProvider);
    _stretchSub = handler.stretchChanges.listen((_) => _refresh());
    _lifecycle = AppLifecycleListener(
      onResume: () {
        _startTimer();
        // Back in front: ask at once.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _refresh();
          if (_due != AsleepAsk.no) unawaited(_ask());
        });
      },
      onPause: () => _timer?.cancel(),
    );
    _startTimer();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(AsleepPromptHost.recheckEvery, (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_stretchSub?.cancel());
    _lifecycle?.dispose();
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    final due = _showing ? AsleepAsk.no : ref.read(asleepGuardProvider).due();
    if (due != _due) setState(() => _due = due);
  }

  Future<void> _ask() async {
    if (_showing || !mounted) return;
    final guard = ref.read(asleepGuardProvider);
    final ask = guard.due();
    if (ask == AsleepAsk.no || !_inForeground) return _refresh();
    final context = widget.navigatorKey.currentContext;
    if (context == null) return;
    final handler = ref.read(audioHandlerProvider);
    final stretch = handler.stretch;
    // Once per stretch, whatever the answer.
    guard.askedStretchId = stretch.id;
    _showing = true;
    setState(() => _due = AsleepAsk.no);
    final body = asleepPromptBody(ask, playing: handler.playing, listenedMs: stretch.listenedMs);
    try {
      final yes = await showAsleepPromptDialog(context, body: _bodyText(body));
      if (!mounted) return;
      if (yes == true) {
        await _search(handler);
      } else {
        await _notAsleep(handler, answered: yes == false);
      }
    } finally {
      _showing = false;
      _refresh();
    }
  }

  static String _bodyText(({AsleepBody key, int minutes}) body) => switch (body.key) {
        AsleepBody.playingOverAnHour => AppStrings.asleepPromptPlayingHour,
        AsleepBody.stoppedOverAnHour => AppStrings.asleepPromptStoppedHour,
        AsleepBody.playingMinutes => AppStrings.asleepPromptPlayingMinutes(body.minutes),
        AsleepBody.stoppedMinutes => AppStrings.asleepPromptStoppedMinutes(body.minutes),
      };

  /// "Ja, Stelle suchen": stop the book (journaled, no awake proof), then
  /// search from the last touch to where it plays or stopped.
  Future<void> _search(FadenAudioHandler handler) async {
    final stretch = await handler.pauseForAsleepSearch();
    await ref.read(fadenStarterProvider).fromStretch(stretch);
  }

  /// "Nein, weiterhören": an awake proof; the book plays on, or starts
  /// again where it stopped. Dismissed without an answer, it counts as
  /// "Nein" only while the book still plays -- a stopped book stays where
  /// it is, with the suspicion, so the position is never lost.
  Future<void> _notAsleep(FadenAudioHandler handler, {required bool answered}) async {
    if (handler.playing) {
      await handler.awake();
      return;
    }
    if (!answered) return;
    // E92: the book ended by itself and the listener heard the end.
    if (handler.stretch.endedAtBookEnd) {
      await handler.confirmBookEnd();
      return;
    }
    final manifest = handler.manifest;
    final at = handler.currentPosition();
    final idx = manifest?.indexOf(at.fileHash) ?? -1;
    await handler.resumeFromStop(at, fileIndex: idx < 0 ? null : idx);
  }

  @override
  Widget build(BuildContext context) {
    // Loaded here so the question knows the night window, and looks again
    // once it is known or changed.
    ref.listen(nightWindowProvider, (_, _) => WidgetsBinding.instance.addPostFrameCallback((_) => _refresh()));
    return Stack(
      textDirection: TextDirection.ltr,
      fit: StackFit.expand,
      children: [
        widget.child,
        if (_due != AsleepAsk.no)
          Positioned.fill(
            // The first touch asks instead of acting (the audit's finding
            // 4): it never reaches the player, so it neither pauses nor
            // writes an AWAKE that would erase the suspicion.
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (_) => unawaited(_ask()),
              child: const SizedBox.expand(),
            ),
          ),
      ],
    );
  }
}

/// The question itself (E84), in the app's look -- dark at night like
/// every dialog (E46): "Ja, Stelle suchen" as the full-width capsule,
/// "Nein, weiterhören" below. Resolves to true (yes), false (no) or null
/// (dismissed).
Future<bool?> showAsleepPromptDialog(BuildContext context, {required String body}) => showDialog<bool>(
      context: context,
      builder: (_) => AsleepPromptDialog(body: body),
    );

class AsleepPromptDialog extends StatelessWidget {
  final String body;

  const AsleepPromptDialog({super.key, required this.body});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(AppStrings.asleepPromptTitle),
      content: Text(body),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      actions: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: fadenMinTapTarget),
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(AppStrings.asleepPromptYes),
              ),
            ),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: fadenMinTapTarget),
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(AppStrings.asleepPromptNo),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
