/// Headphone gestures in the Faden search (decision E85). Pure, no I/O.
///
/// How the buttons arrive (checked in audio_service 0.18.19,
/// `darwin/.../AudioServicePlugin.m` and `BaseAudioHandler.click`): on
/// iOS a single press is `togglePlayPauseCommand` (always enabled) ->
/// `click` -> `play()`/`pause()`, or `playCommand`/`pauseCommand`
/// directly. Faden publishes the controls rewind, play/pause and fast
/// forward, so audio_service enables `skipForwardCommand` and
/// `skipBackwardCommand` (-> `fastForward()`/`rewind()`) and leaves
/// `nextTrackCommand`/`previousTrackCommand` (-> `skipToNext()`/
/// `skipToPrevious()`) off; iOS then delivers a double press as skip
/// forward and a triple press as skip back. Some headphones and Android
/// send next/previous track instead, so both pairs map the same.
library;

/// A transport command the audio handler received from outside the app.
enum RemoteCommand { play, pause, next, previous, fastForward, rewind }

/// Where the Faden search stands for the buttons.
enum FadenRemotePhase {
  /// A probe is asked (or about to be): every button answers.
  search,

  /// The result plays: only "Etwas früher anfangen" is taken over.
  result,
}

/// What a button means in the Faden search.
enum FadenGesture {
  /// 1x: "Kenne ich".
  known,

  /// 2x: "Kenne ich nicht".
  unknown,

  /// 3x: "Nochmal hören".
  replay,

  /// 3x on the result: "Etwas früher anfangen".
  earlier,
}

/// The meaning of [command] in [phase], or null when the button should act
/// normally (on the result everything but 3x, and 3x too once there is no
/// earlier passage left).
FadenGesture? fadenGestureFor(RemoteCommand command, FadenRemotePhase phase, {bool canGoEarlier = false}) {
  switch (phase) {
    case FadenRemotePhase.search:
      return switch (command) {
        RemoteCommand.play || RemoteCommand.pause => FadenGesture.known,
        RemoteCommand.next || RemoteCommand.fastForward => FadenGesture.unknown,
        RemoteCommand.previous || RemoteCommand.rewind => FadenGesture.replay,
      };
    case FadenRemotePhase.result:
      final back = command == RemoteCommand.previous || command == RemoteCommand.rewind;
      return back && canGoEarlier ? FadenGesture.earlier : null;
  }
}
