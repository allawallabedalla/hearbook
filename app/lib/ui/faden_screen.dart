import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' as ja;

import '../audio/handler.dart';
import '../audio/probe_player.dart';
import '../domain/faden_search.dart' as fs;
import '../domain/manifest.dart';
import '../l10n/strings.dart';
import 'faden_search_controller.dart';
import 'format.dart';
import 'providers.dart';
import 'routes.dart' show reduceMotion;
import 'theme.dart';

/// docs/KONZEPT.md "Faden-Modus": "Vollbild, dunkel, siehe oben [Faden
/// aufnehmen]." Full-screen, always the night palette regardless of the
/// actual night view (the whole point is a calm, low-light search screen):
/// true black, dim ink, no cover, title or transport controls (that is also
/// what lets audio/handler.dart treat every hardware media-button call
/// received while this screen is open as "kenne ich", see its
/// `enterFadenMode` doc comment).
///
/// Decision E64: the search proposes passages visibly. The passage being
/// asked is a card ("Probe 2 von höchstens 8", where it lies, how long
/// before the stop, the probe + answer window running out) with two big
/// buttons, "Kenne ich" and "Kenne ich nicht", and "Nochmal hören"; the
/// passages already heard are listed below with their answers. A tap on
/// empty space answers nothing. Long press or "Abbrechen" aborts. The
/// result names the passage playback starts at and offers the recognised
/// passages -- never later than the result (invariant 9) -- and "Früher".
class FadenScreen extends ConsumerStatefulWidget {
  final Manifest manifest;

  /// `last_awake`, global ms.
  final int lo;

  /// `stop`, global ms (or earlier, from a local sleep-onset reading).
  final int hi;

  /// The stop point itself, global ms, which the probes are shown
  /// relative to ("4 Min. vor dem Stopp"); [hi] if not given.
  final int? stop;

  /// Sentence-start offsets, global ms (domain/pause_index.dart).
  final List<int> pausen;

  /// Optional local-health-data first guess (docs/ARCHITEKTUR.md section 9,
  /// M6) -- forwarded to [FadenSearchController]. Null reproduces M5's
  /// behaviour exactly.
  final int? prior;

  final List<ja.IndexedAudioSource> playlistSources;

  /// Test seam: a probe player to use instead of a fresh [ProbePlayer]
  /// (which wraps a real just_audio instance). The screen disposes it.
  final ProbePlayer? probePlayer;

  const FadenScreen({
    super.key,
    required this.manifest,
    required this.lo,
    required this.hi,
    this.stop,
    required this.pausen,
    this.prior,
    required this.playlistSources,
    this.probePlayer,
  });

  @override
  ConsumerState<FadenScreen> createState() => _FadenScreenState();
}

class _FadenScreenState extends ConsumerState<FadenScreen> with SingleTickerProviderStateMixin {
  /// Captured once in [initState]: the search's callbacks and [dispose] may
  /// run after this widget is unmounted, where `ref` must not be used.
  late final FadenAudioHandler _handler;
  late final ProbePlayer _probePlayer;
  late final FadenSearchController _controller;
  StreamSubscription<void>? _mediaAnswerSub;
  StreamSubscription<FadenProgress>? _progressSub;
  FadenProgress? _progress;

  /// The probe + answer window of the passage being asked (4 s + 3 s),
  /// restarted with every new window ([FadenProgress.window]).
  late final AnimationController _windowClock;
  int _window = 0;

  /// Set once the search has its result and playback runs.
  bool _found = false;

  /// Where playback was last started (global ms): the result, a tapped
  /// passage or a "Früher" step.
  int? _playingMs;

  /// A RESUME is being written: further taps wait.
  bool _resuming = false;

  @override
  void initState() {
    super.initState();
    final handler = _handler = ref.read(audioHandlerProvider);
    handler.enterFadenMode();

    _windowClock = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: fs.probeLen + fs.answerWindow),
    );

    _probePlayer = widget.probePlayer ?? ProbePlayer();
    _probePlayer.open(widget.playlistSources);

    // A headphone button still means "Kenne ich".
    _mediaAnswerSub = handler.fadenModeAnswers.listen((_) {
      unawaited(HapticFeedback.selectionClick());
      _controller.submitAnswer();
    });

    _controller = FadenSearchController(
      lo: widget.lo,
      hi: widget.hi,
      pausen: widget.pausen,
      prior: widget.prior,
      playTone: _probePlayer.playTone,
      playProbe: (p) {
        final pos = widget.manifest.positionForGlobalMs(p);
        final idx = widget.manifest.indexOf(pos.fileHash);
        if (idx < 0) return Future.value();
        return _probePlayer.playProbe(
          fileIndex: idx,
          offsetMs: pos.offsetMs,
          probeLenMs: fs.probeLen,
          fileDurationMs: widget.manifest.files[idx].durationMs,
        );
      },
      stopProbe: _probePlayer.stop,
      onProbeAnswered: (p, known) {
        final pos = widget.manifest.positionForGlobalMs(p);
        return handler.probe(position: pos, known: known);
      },
      onResumeAt: _handleResolved,
      onAborted: _handleAborted,
    );
    _progressSub = _controller.progress.listen(_onProgress);

    unawaited(_controller.start());
  }

  void _onProgress(FadenProgress p) {
    if (!mounted) return;
    setState(() => _progress = p);
    if (p.window != _window) {
      _window = p.window;
      unawaited(_windowClock.forward(from: 0));
    } else if (!p.listening) {
      _windowClock.stop();
    }
  }

  /// The search's own finding, a tapped passage, or a "Früher" step (all
  /// call [FadenSearchController.onResumeAt]): resume playback there and
  /// show the result -- "Gefunden. Weiter ab hier." with the passage, the
  /// recognised alternatives and "Früher" -- instead of closing at once.
  Future<void> _handleResolved(int globalMs) async {
    await _resumeTo(globalMs);
    _windowClock.stop();
    if (mounted) {
      setState(() {
        _found = true;
        _playingMs = globalMs;
      });
    }
  }

  /// Long-press or "Abbrechen" abort (docs/KONZEPT.md: "... startet am
  /// letzten sicheren Wach-Punkt."): resume there and close straight back
  /// to the player, no intermediate "Gefunden" state.
  Future<void> _handleAborted(int globalMs) async {
    await _resumeTo(globalMs);
    if (mounted) _closeToPlayer();
  }

  Future<void> _resumeTo(int globalMs) async {
    final pos = widget.manifest.positionForGlobalMs(globalMs);
    final idx = widget.manifest.indexOf(pos.fileHash);
    await _handler.resumeFromFaden(pos, fileIndex: idx < 0 ? null : idx);
  }

  void _closeToPlayer() {
    _handler.exitFadenMode();
    Navigator.of(context).pop();
  }

  void _answer({required bool known}) {
    if (_found) return;
    // Felt as well as seen: the screen stays dark (E44).
    unawaited(HapticFeedback.selectionClick());
    _controller.answer(known: known);
  }

  void _abort() {
    if (_found) return;
    _controller.abort();
  }

  Future<void> _resumeWith(Future<void> Function() resume) async {
    if (_resuming) return;
    _resuming = true;
    try {
      await resume();
    } finally {
      _resuming = false;
    }
  }

  @override
  void dispose() {
    // Also the path for leaving without a result (back gesture / route
    // pop): end the search silently (no further PROBE, no RESUME, no
    // playback start), stop the probe, and leave Faden mode so media
    // buttons act normally again. Idempotent after [_closeToPlayer].
    _mediaAnswerSub?.cancel();
    _progressSub?.cancel();
    _controller.dispose();
    _windowClock.dispose();
    _handler.exitFadenMode();
    unawaited(_probePlayer.dispose());
    super.dispose();
  }

  /// "Kapitel 5 · 23:14".
  String _passage(int globalMs) {
    final pos = widget.manifest.positionForGlobalMs(globalMs);
    final idx = widget.manifest.indexOf(pos.fileHash);
    return AppStrings.fadenPassage(AppStrings.chapterLabel(idx + 1), formatClock(pos.offsetMs));
  }

  /// "4 Min. vor dem Stopp".
  String _beforeStop(int globalMs) =>
      AppStrings.fadenBeforeStop(formatBeforeStop((widget.stop ?? widget.hi) - globalMs));

  @override
  Widget build(BuildContext context) {
    final tokens = FadenTokens.night;
    return Theme(
      data: buildFadenTheme(tokens),
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          backgroundColor: tokens.grund,
          body: SafeArea(
            // Readable up to 1.6x, like the player (E44).
            child: MediaQuery.withClampedTextScaling(
              maxScaleFactor: 1.6,
              // Long press anywhere aborts (docs/KONZEPT.md); a plain tap
              // on empty space answers nothing (E64). Kept out of the
              // semantics tree, so VoiceOver reads every text and button on
              // its own; it has "Abbrechen" for the abort.
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                excludeFromSemantics: true,
                onLongPress: _abort,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: _found ? _result(tokens) : _search(tokens),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _search(FadenTokens tokens) {
    final progress = _progress;
    final windowMs = widget.hi - widget.lo;
    final remainingMs = progress == null ? windowMs : (progress.hi - progress.lo);
    final fraction = windowMs <= 0 ? 0.0 : (remainingMs / windowMs).clamp(0.0, 1.0);
    final current = progress?.current;
    final listening = progress?.listening ?? false;
    final heard = progress?.heard ?? const <FadenProbe>[];
    final caption = TextStyle(fontSize: FadenTypeSizes.caption, color: tokens.tinteLeise);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                (progress?.probeNr ?? 0) == 0 ? '' : AppStrings.fadenProbeCounter(progress!.probeNr, fs.maxProbes),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: FadenTypeSizes.body, color: tokens.tinte),
              ),
            ),
            Semantics(
              hint: AppStrings.fadenAbortHint,
              child: TextButton(
                onPressed: _abort,
                onLongPress: _abort,
                style: TextButton.styleFrom(foregroundColor: tokens.tinteLeise),
                child: Text(AppStrings.fadenAbort, style: const TextStyle(fontSize: FadenTypeSizes.body)),
              ),
            ),
          ],
        ),
        // docs/KONZEPT.md "Bewegung": "im Faden-Modus wird der Faden mit
        // jeder Antwort kürzer (300 ms)" -- unless the system asks for
        // reduced motion.
        LayoutBuilder(
          builder: (context, constraints) => Align(
            alignment: Alignment.centerLeft,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: AnimatedContainer(
                duration: reduceMotion(context) ? Duration.zero : const Duration(milliseconds: 300),
                curve: Curves.easeOut,
                height: 3,
                width: constraints.maxWidth * fraction,
                color: tokens.faden,
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        _ProbeCard(
          tokens: tokens,
          passage: current == null ? null : _passage(current.p),
          beforeStop: current == null ? null : _beforeStop(current.p),
          windowClock: _windowClock,
          onReplay: listening ? _controller.replay : null,
        ),
        const SizedBox(height: 16),
        FadenAnswerButton(
          label: AppStrings.fadenKnown,
          tokens: tokens,
          primary: true,
          onPressed: listening ? () => _answer(known: true) : null,
        ),
        const SizedBox(height: 12),
        FadenAnswerButton(
          label: AppStrings.fadenUnknown,
          tokens: tokens,
          primary: false,
          onPressed: listening ? () => _answer(known: false) : null,
        ),
        const SizedBox(height: 16),
        if (heard.isNotEmpty) Text(AppStrings.fadenHeardTitle, style: caption),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              // The latest first.
              for (final probe in heard.reversed)
                _HeardRow(
                  key: ValueKey('faden-heard-${probe.probeNr}'),
                  tokens: tokens,
                  passage: _passage(probe.p),
                  known: probe.known ?? false,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _result(FadenTokens tokens) {
    final playing = _playingMs;
    final leiter = _controller.leiter;
    final resultIndex = _controller.resultIndex;
    // The recognised passages, the result first, then earlier ones --
    // never anything later than the result (invariant 9).
    final alternatives = [
      for (var i = resultIndex; i >= 1; i--) i,
    ];
    final showAlternatives = alternatives.any((i) => i != _controller.leiterIndex);
    final caption = TextStyle(fontSize: FadenTypeSizes.caption, color: tokens.tinteLeise);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _closeToPlayer,
            style: TextButton.styleFrom(foregroundColor: tokens.faden),
            child: Text(AppStrings.fadenDone, style: const TextStyle(fontSize: FadenTypeSizes.body)),
          ),
        ),
        Text(
          AppStrings.fadenResultFound,
          style: TextStyle(fontSize: FadenTypeSizes.title, color: tokens.tinte),
        ),
        const SizedBox(height: 12),
        if (playing != null)
          _PassageCard(
            tokens: tokens,
            children: [
              Text(
                _passage(playing),
                style: TextStyle(fontSize: FadenTypeSizes.title, color: tokens.faden),
              ),
              const SizedBox(height: 4),
              Text(_beforeStop(playing), style: caption),
            ],
          ),
        if (_controller.canGoEarlier) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => unawaited(_resumeWith(_controller.earlier)),
              style: TextButton.styleFrom(foregroundColor: tokens.faden),
              icon: const Icon(Icons.fast_rewind_outlined),
              label: Text(AppStrings.fadenLadderEarlier, style: const TextStyle(fontSize: FadenTypeSizes.body)),
            ),
          ),
        ],
        const SizedBox(height: 16),
        if (showAlternatives) Text(AppStrings.fadenAlternativesTitle, style: caption),
        Expanded(
          child: showAlternatives
              ? ListView(
                  padding: const EdgeInsets.only(bottom: 16),
                  children: [
                    for (final i in alternatives)
                      _AlternativeRow(
                        key: ValueKey('faden-alternative-$i'),
                        tokens: tokens,
                        passage: _passage(leiter[i]),
                        beforeStop: _beforeStop(leiter[i]),
                        playing: i == _controller.leiterIndex,
                        onTap: () => unawaited(_resumeWith(() => _controller.resumeAtLeiterIndex(i))),
                      ),
                  ],
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// A quiet frame around a passage: a thin `tinte-leise` line on black.
class _PassageCard extends StatelessWidget {
  final FadenTokens tokens;
  final List<Widget> children;

  const _PassageCard({required this.tokens, required this.children});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: tokens.tinteLeiseFaden),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      ),
    );
  }
}

/// The passage being asked (E64): the question, where it lies, how long
/// before the stop, the probe + answer window running out, "Nochmal
/// hören". Before the first probe it says one is coming.
class _ProbeCard extends StatelessWidget {
  final FadenTokens tokens;
  final String? passage;
  final String? beforeStop;
  final Animation<double> windowClock;
  final VoidCallback? onReplay;

  const _ProbeCard({
    required this.tokens,
    required this.passage,
    required this.beforeStop,
    required this.windowClock,
    required this.onReplay,
  });

  @override
  Widget build(BuildContext context) {
    final passage = this.passage;
    return _PassageCard(
      tokens: tokens,
      children: [
        Text(
          passage == null ? AppStrings.fadenStarting : AppStrings.fadenModePrompt,
          style: TextStyle(fontSize: FadenTypeSizes.title, color: tokens.tinte),
        ),
        if (passage != null) ...[
          const SizedBox(height: 8),
          Text(passage, style: TextStyle(fontSize: FadenTypeSizes.body, color: tokens.faden)),
          if (beforeStop != null)
            Text(beforeStop!, style: TextStyle(fontSize: FadenTypeSizes.caption, color: tokens.tinteLeise)),
        ],
        const SizedBox(height: 12),
        AnimatedBuilder(
          animation: windowClock,
          builder: (context, _) => LinearProgressIndicator(
            value: windowClock.value,
            minHeight: 3,
            color: tokens.faden,
            backgroundColor: tokens.tinteLeiseFaden,
            semanticsLabel: AppStrings.fadenAnswerWindow,
          ),
        ),
        const SizedBox(height: 4),
        TextButton.icon(
          onPressed: onReplay,
          onLongPress: onReplay,
          style: TextButton.styleFrom(foregroundColor: tokens.tinte, padding: EdgeInsets.zero),
          icon: const Icon(Icons.replay),
          label: Text(AppStrings.fadenReplay, style: const TextStyle(fontSize: FadenTypeSizes.body)),
        ),
      ],
    );
  }
}

/// "Kenne ich" / "Kenne ich nicht" (E64): full width, at least 56 dp,
/// only a ring (no lit surface at night, like the night main button). A
/// long press counts as a tap, so holding the button never aborts.
class FadenAnswerButton extends StatelessWidget {
  final String label;
  final FadenTokens tokens;
  final bool primary;
  final VoidCallback? onPressed;

  const FadenAnswerButton({
    super.key,
    required this.label,
    required this.tokens,
    required this.primary,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final color = primary ? tokens.faden : tokens.tinte;
    return OutlinedButton(
      onPressed: onPressed,
      onLongPress: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        minimumSize: const Size.fromHeight(fadenMinTapTarget),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        shape: const StadiumBorder(),
        side: BorderSide(color: onPressed == null ? tokens.tinteLeiseFaden : color, width: primary ? 2 : 1),
      ),
      child: Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: FadenTypeSizes.title)),
    );
  }
}

/// A passage already heard in this search, with its answer.
class _HeardRow extends StatelessWidget {
  final FadenTokens tokens;
  final String passage;
  final bool known;

  const _HeardRow({super.key, required this.tokens, required this.passage, required this.known});

  @override
  Widget build(BuildContext context) {
    final answer = known ? AppStrings.fadenHeardKnown : AppStrings.fadenHeardUnknown;
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(known ? Icons.check : Icons.close, size: 18, color: known ? tokens.faden : tokens.tinteLeise),
            const SizedBox(width: 12),
            Expanded(
              child: Text(passage, style: TextStyle(fontSize: FadenTypeSizes.body, color: tokens.tinte)),
            ),
            const SizedBox(width: 8),
            Text(answer, style: TextStyle(fontSize: FadenTypeSizes.caption, color: tokens.tinteLeise)),
          ],
        ),
      ),
    );
  }
}

/// A recognised passage on the result (E64): tap to continue there.
class _AlternativeRow extends StatelessWidget {
  final FadenTokens tokens;
  final String passage;
  final String beforeStop;
  final bool playing;
  final VoidCallback onTap;

  const _AlternativeRow({
    super.key,
    required this.tokens,
    required this.passage,
    required this.beforeStop,
    required this.playing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: playing,
      child: InkWell(
        onTap: playing ? null : onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: fadenMinTapTarget),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Icon(Icons.play_arrow, size: 20, color: playing ? tokens.faden : tokens.tinteLeise),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(passage, style: TextStyle(fontSize: FadenTypeSizes.body, color: tokens.tinte)),
                      Text(
                        beforeStop,
                        style: TextStyle(fontSize: FadenTypeSizes.caption, color: tokens.tinteLeise),
                      ),
                    ],
                  ),
                ),
                if (playing) ...[
                  const SizedBox(width: 8),
                  Text(
                    AppStrings.fadenPlaying,
                    style: TextStyle(fontSize: FadenTypeSizes.caption, color: tokens.faden),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
