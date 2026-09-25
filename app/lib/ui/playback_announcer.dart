import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/handler.dart';
import '../audio/playback_status.dart';
import '../audio/undo_hint.dart';
import '../domain/event.dart' show EventSource;
import '../l10n/strings.dart';
import 'providers.dart';

/// Announces what the handler reports, on whatever screen is in front:
/// undo hints for jumps over 2 min (invariant 6) and playback errors (E39,
/// E58). It sits above the navigator (main.dart's `MaterialApp.builder`)
/// since decision E60: the player is a route that closes, and an error
/// from the mini player's play button must still show in the library.
/// Uses the root ScaffoldMessenger, so a SnackBar takes the look of the
/// screen it appears on (the night player's included, E46).
class PlaybackAnnouncer extends ConsumerStatefulWidget {
  final Widget child;

  const PlaybackAnnouncer({super.key, required this.child});

  @override
  ConsumerState<PlaybackAnnouncer> createState() => _PlaybackAnnouncerState();
}

class _PlaybackAnnouncerState extends ConsumerState<PlaybackAnnouncer> {
  late final FadenAudioHandler _handler;
  final List<StreamSubscription<Object?>> _subs = [];

  /// The first undo hint that arrived while the Faden screen was open. It
  /// must not appear over that screen (where a tap means "kenne ich" or
  /// "close") and would likely time out before the listener is back.
  UndoHint? _heldUndoHint;

  /// The playback error a SnackBar was shown for, so one error is
  /// announced once.
  PlaybackFailure? _shownError;

  @override
  void initState() {
    super.initState();
    _handler = ref.read(audioHandlerProvider);
    _subs.add(_handler.undoHints.listen(_onUndoHint));
    _subs.add(_handler.statusStream.listen((status) => unawaited(_onStatus(status))));
    // An error from before this widget existed (opening the last book at
    // app start) would otherwise never be announced.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_onStatus(_handler.status));
    });
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    super.dispose();
  }

  bool get _fadenOpen => ref.read(fadenScreenOpenProvider);

  void _onUndoHint(UndoHint hint) {
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
          label: hint.actionLabel ?? AppStrings.undoAction,
          onPressed: () {
            unawaited(HapticFeedback.lightImpact());
            unawaited(_handler.undo(hint.target));
          },
        ),
        duration: const Duration(seconds: 8),
        // A SnackBar with an action persists by default in current Flutter,
        // which would ignore the duration and leave the hint up for good.
        persist: false,
      ),
    );
  }

  /// E39: a playback error shows once as "Kann nicht abspielen" with a
  /// retry; the next play reloads the playlist (audio/handler.dart).
  ///
  /// E58: if the failing chapter is not downloaded and the server does not
  /// answer (the NAS is off at night), it says exactly that instead.
  Future<void> _onStatus(PlaybackStatus status) async {
    final error = status.error;
    if (error == null) {
      _shownError = null;
      return;
    }
    if (error == _shownError || !mounted || _fadenOpen) return;
    _shownError = error;
    final messenger = ScaffoldMessenger.of(context);
    var text = AppStrings.playbackError;
    if (error.notDownloaded && !await ref.read(serverReachableProvider)()) {
      text = AppStrings.offlineNotDownloaded;
    }
    if (!mounted || _shownError != error) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(text),
        action: SnackBarAction(
          label: AppStrings.libraryRetry,
          onPressed: () => unawaited(_handler.playFrom(EventSource.ui)),
        ),
        duration: const Duration(seconds: 10),
        persist: false,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Back from the Faden screen: the held hint appears now.
    ref.listen<bool>(fadenScreenOpenProvider, (_, open) {
      if (open) return;
      final held = _heldUndoHint;
      _heldUndoHint = null;
      if (held != null) _onUndoHint(held);
    });
    return widget.child;
  }
}
