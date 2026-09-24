/// What the UI needs to show about the main player beyond position
/// (decision E39): whether it plays, whether it waits for data, and the
/// last playback error. Free of just_audio types so widgets and tests can
/// build it directly.
class PlaybackStatus {
  /// The player intends to play (just_audio's `playing`).
  final bool playing;

  /// Playing, but waiting for audio data (loading or buffering). The UI
  /// shows a spinner instead of the pause symbol.
  final bool buffering;

  /// The last playback error, until playback starts again successfully.
  final PlaybackFailure? error;

  const PlaybackStatus({required this.playing, required this.buffering, this.error});

  static const idle = PlaybackStatus(playing: false, buffering: false);

  PlaybackStatus copyWith({bool? playing, bool? buffering, PlaybackFailure? error, bool clearError = false}) =>
      PlaybackStatus(
        playing: playing ?? this.playing,
        buffering: buffering ?? this.buffering,
        error: clearError ? null : (error ?? this.error),
      );

  @override
  bool operator ==(Object other) =>
      other is PlaybackStatus &&
      other.playing == playing &&
      other.buffering == buffering &&
      other.error == error;

  @override
  int get hashCode => Object.hash(playing, buffering, error);
}

/// A playback error as the platform reported it (not meant for display as
/// is: the UI shows its own German text).
class PlaybackFailure {
  final int? code;
  final String? message;

  /// Playlist index (0-based chapter) the error belongs to, if known.
  final int? chapterIndex;

  /// The chapter was to stream from the server, not play from a download
  /// (decision E58). With the server unreachable, the UI says so plainly
  /// instead of "Kann nicht abspielen".
  final bool notDownloaded;

  const PlaybackFailure({this.code, this.message, this.chapterIndex, this.notDownloaded = false});

  @override
  bool operator ==(Object other) =>
      other is PlaybackFailure &&
      other.code == code &&
      other.message == message &&
      other.chapterIndex == chapterIndex &&
      other.notDownloaded == notDownloaded;

  @override
  int get hashCode => Object.hash(code, message, chapterIndex, notDownloaded);
}

/// Processing states of the main player, mirrored from just_audio's
/// `ProcessingState` so [isBuffering] stays a pure function.
enum PlayerPhase { idle, loading, buffering, ready, completed }

/// Whether the UI should show "waiting for audio": playback is wanted but
/// the player is still loading or buffering.
bool isBuffering({required bool playing, required PlayerPhase phase}) =>
    playing && (phase == PlayerPhase.loading || phase == PlayerPhase.buffering);

/// Whether a playlist index change from [previous] to [next] is playback
/// running into the next chapter on its own, as opposed to a seek this app
/// made ([expectedSeekIndex], the index the last seek/open targeted) or a
/// jump backwards. The "Kapitelende" sleep timer (signals/sleep_timer.dart)
/// fires only on such a natural advance.
bool isNaturalChapterAdvance({required int? previous, required int next, required int? expectedSeekIndex}) {
  if (previous == null) return false;
  if (next == expectedSeekIndex) return false;
  return next == previous + 1;
}
