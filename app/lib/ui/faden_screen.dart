import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' as ja;

import '../audio/probe_player.dart';
import '../domain/faden_search.dart' as fs;
import '../domain/manifest.dart';
import '../l10n/strings.dart';
import '../signals/screen_awake.dart';
import 'faden_search_controller.dart';
import 'faden_session.dart';
import 'providers.dart';
import 'routes.dart' show reduceMotion;
import 'theme.dart';

/// docs/KONZEPT.md "Faden-Modus": "Vollbild, dunkel, siehe oben [Faden
/// aufnehmen]." Full-screen, always the night palette regardless of the
/// actual night view (the whole point is a calm, low-light search screen):
/// true black, dim ink, no cover, title or transport controls.
///
/// Decision E64: the search proposes passages visibly. The passage being
/// asked is a card (how many questions are left at most, when it was
/// heard, how long before it stopped, the probe + answer window running
/// out) with two big buttons, "Kenne ich" and "Kenne ich nicht", and
/// "Nochmal hören"; the passages already asked are listed below with their
/// answers. A tap on empty space answers nothing. "Abbrechen" returns to
/// the player without changing anything (E89). The result says honestly
/// what happened (E88), offers the recognised passages -- never later than
/// the result (invariant 9) -- "Etwas früher anfangen" and "Nochmal prüfen"
/// for the earliest passage not recognised (E91).
///
/// Since decision E85 the search itself is a [FadenSession] that can run
/// without this screen (a play from the lock screen); the screen shows
/// one, keeps the display from locking while it is open, and ends the
/// session when it is left.
class FadenScreen extends ConsumerStatefulWidget {
  /// The session to show; null: the screen starts its own from the
  /// parameters below (tests, and before E85 every caller).
  final FadenSession? session;

  final Manifest manifest;

  /// `last_awake`, global ms.
  final int lo;

  /// `stop`, global ms (or earlier, from a local sleep-onset reading).
  final int hi;

  /// The stop point itself, global ms, which the probes are shown
  /// relative to ("4 Min. bevor es anhielt"); [hi] if not given.
  final int? stop;

  /// Sentence-start offsets, global ms (domain/pause_index.dart).
  final List<int> pausen;

  /// Optional local-health-data first guess (docs/ARCHITEKTUR.md section 9,
  /// M6) -- forwarded to [FadenSearchController]. Null reproduces M5's
  /// behaviour exactly.
  final int? prior;

  /// Whether [prior] was learned from earlier searches (decision E78):
  /// probe 1 still runs first.
  final bool priorAfterFalseAlarm;

  /// The probe length setting (decision E77).
  final int probeLen;

  /// Every start from the result, see [FadenSearchController.onChosen].
  final Future<void> Function(int globalMs, bool recognised)? onChosen;

  final List<ja.IndexedAudioSource> playlistSources;

  /// Test seam: a probe player to use instead of a fresh [ProbePlayer]
  /// (which wraps a real just_audio instance). The session disposes it.
  final ProbePlayer? probePlayer;

  const FadenScreen({
    super.key,
    required this.manifest,
    required this.lo,
    required this.hi,
    this.stop,
    required this.pausen,
    this.prior,
    this.priorAfterFalseAlarm = false,
    this.probeLen = fs.defaultProbeLen,
    this.onChosen,
    required this.playlistSources,
    this.probePlayer,
  }) : session = null;

  /// Shows [session], which runs already (ui/faden_session_host.dart).
  FadenScreen.forSession(FadenSession this.session, {super.key})
      : manifest = session.manifest,
        lo = session.lo,
        hi = session.hi,
        stop = session.stop,
        pausen = const [],
        prior = null,
        priorAfterFalseAlarm = false,
        probeLen = session.probeLen,
        onChosen = null,
        playlistSources = const [],
        probePlayer = null;

  @override
  ConsumerState<FadenScreen> createState() => _FadenScreenState();
}

class _FadenScreenState extends ConsumerState<FadenScreen> with SingleTickerProviderStateMixin {
  /// Captured once in [initState]: [dispose] runs after this widget is
  /// unmounted, where `ref` must not be used.
  late final FadenSession _session;
  late final bool _ownsSession;
  ScreenAwake? _screenAwake;

  /// The probe + answer window of the passage being asked (6 s + 3 s by
  /// default), restarted with every new window ([FadenProgress.window]).
  late final AnimationController _windowClock;
  int _window = 0;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    final given = widget.session;
    if (given != null) {
      _session = given;
      _ownsSession = false;
    } else {
      _session = FadenSession(
        handler: ref.read(audioHandlerProvider),
        manifest: widget.manifest,
        lo: widget.lo,
        hi: widget.hi,
        stop: widget.stop,
        pausen: widget.pausen,
        playlistSources: widget.playlistSources,
        prior: widget.prior,
        priorAfterFalseAlarm: widget.priorAfterFalseAlarm,
        probeLen: widget.probeLen,
        onChosen: widget.onChosen,
        probePlayer: widget.probePlayer,
      );
      _ownsSession = true;
    }
    _windowClock = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: _session.probeLen + fs.answerWindow),
    );
    _session.addListener(_onSession);
    _session.attachScreen();
    if (_ownsSession) _session.start();
    // E85: the phone must not lock itself between two probes.
    _screenAwake = ref.read(screenAwakeProvider);
    unawaited(_screenAwake?.keepOn(true));
    final p = _session.progress;
    if (p != null && p.listening) {
      _window = p.window;
      unawaited(_windowClock.forward(from: 0));
    }
    if (_session.ended) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _leave());
    }
  }

  void _onSession() {
    if (!mounted) return;
    if (_session.ended) {
      _leave();
      return;
    }
    final p = _session.progress;
    if (p != null) {
      if (p.window != _window) {
        _window = p.window;
        unawaited(_windowClock.forward(from: 0));
      } else if (!p.listening) {
        _windowClock.stop();
      }
    }
    if (!_session.asking) _windowClock.stop();
    setState(() {});
  }

  /// Back to the player (the session ended, "Abbrechen", "Fertig").
  void _leave() {
    if (_leaving || !mounted) return;
    _leaving = true;
    unawaited(_screenAwake?.keepOn(false));
    Navigator.of(context).maybePop();
  }

  void _answer({required bool known}) {
    if (!_session.asking) return;
    // Felt as well as seen: the screen stays dark (E44).
    unawaited(HapticFeedback.selectionClick());
    _session.answer(known: known);
  }

  /// "Abbrechen" (E89): nothing changes, back to the player.
  void _cancel() {
    unawaited(_session.cancel());
  }

  /// "Fertig": the result plays on, back to the player.
  void _done() {
    unawaited(_session.close());
  }

  @override
  void dispose() {
    // Also the path for leaving by a back gesture: before the result the
    // search ends silently (no further PROBE, no RESUME, no playback
    // start, E89); on the result, playback just goes on.
    _session.removeListener(_onSession);
    _session.detachScreen();
    if (!_session.ended) {
      unawaited(_session.found ? _session.close() : _session.cancel());
    }
    unawaited(_screenAwake?.keepOn(false));
    _windowClock.dispose();
    if (_ownsSession) _session.dispose();
    super.dispose();
  }

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
              // A plain tap on empty space answers nothing (E64); a long
              // press no longer aborts (E89): "Abbrechen" is the one way out.
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: _session.asking ? _search(tokens) : _result(tokens),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _search(FadenTokens tokens) {
    final progress = _session.progress;
    final windowMs = widget.hi - widget.lo;
    final remainingMs = progress == null ? windowMs : (progress.hi - progress.lo);
    final fraction = windowMs <= 0 ? 0.0 : (remainingMs / windowMs).clamp(0.0, 1.0);
    final current = progress?.current;
    final listening = progress?.listening ?? false;
    final rechecking = progress?.rechecking ?? false;
    final heard = progress?.heard ?? const <FadenProbe>[];
    final caption = TextStyle(fontSize: FadenTypeSizes.caption, color: tokens.tinteLeise);
    final probeNr = progress?.probeNr ?? 0;
    final counter = rechecking
        ? AppStrings.fadenRecheck
        : probeNr == 0
            ? ''
            : AppStrings.fadenQuestionsLeft(fs.remainingQuestions(probeNr: probeNr, windowMs: windowMs));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                counter,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: FadenTypeSizes.body, color: tokens.tinte),
              ),
            ),
            Semantics(
              hint: AppStrings.fadenAbortHint,
              child: TextButton(
                onPressed: _cancel,
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
          passage: current == null ? null : _session.passageLabel(current.p),
          beforeStop: current == null ? null : _session.beforeStopLabel(current.p),
          windowClock: _windowClock,
          onReplay: listening ? _session.replay : null,
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
                  key: ValueKey('faden-heard-${probe.probeNr}-${probe.p}'),
                  tokens: tokens,
                  passage: _session.passageLabel(probe.p),
                  known: probe.known ?? false,
                ),
            ],
          ),
        ),
      ],
    );
  }

  String _headline() => switch (_session.resultKind) {
        fs.FadenResultKind.found => AppStrings.fadenResultFound,
        fs.FadenResultKind.stillAwake => AppStrings.fadenResultStillAwake,
        fs.FadenResultKind.nothingRecognised => AppStrings.fadenResultNothing,
        fs.FadenResultKind.lastTouch => AppStrings.fadenResultLastTouch,
      };

  Widget _result(FadenTokens tokens) {
    final controller = _session.controller;
    final playing = _session.playingMs;
    final leiter = controller.leiter;
    final resultIndex = controller.resultIndex;
    // The recognised passages, the result first, then earlier ones --
    // never anything later than the result (invariant 9).
    final alternatives = [
      for (var i = resultIndex; i >= 1; i--) i,
    ];
    final showAlternatives = alternatives.any((i) => i != controller.leiterIndex);
    final recheck = _session.recheckMs;
    final caption = TextStyle(fontSize: FadenTypeSizes.caption, color: tokens.tinteLeise);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        // "**Gefunden.** Weiter ab hier." (E76): the first sentence bold.
        Text.rich(
          _firstSentenceBold(_headline()),
          style: TextStyle(fontSize: FadenTypeSizes.display, color: tokens.tinte, height: 1.2),
        ),
        const SizedBox(height: 12),
        if (playing != null)
          _PassageCard(
            tokens: tokens,
            children: [
              Text(
                _session.passageLabel(playing),
                style: TextStyle(fontSize: FadenTypeSizes.title, color: tokens.faden),
              ),
              const SizedBox(height: 4),
              Text(_session.beforeStopLabel(playing), style: caption),
            ],
          ),
        if (controller.canGoEarlier) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => unawaited(_session.earlier()),
              style: TextButton.styleFrom(foregroundColor: tokens.faden),
              icon: const Icon(Icons.fast_rewind_outlined),
              label: Text(AppStrings.fadenLadderEarlier, style: const TextStyle(fontSize: FadenTypeSizes.body)),
            ),
          ),
        ],
        const SizedBox(height: 16),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              if (recheck != null)
                _RecheckRow(
                  key: ValueKey('faden-recheck-$recheck'),
                  tokens: tokens,
                  passage: _session.passageLabel(recheck),
                  beforeStop: _session.beforeStopLabel(recheck),
                  onTap: () => unawaited(_session.recheck()),
                ),
              if (showAlternatives) ...[
                Padding(
                  padding: EdgeInsets.only(top: recheck != null ? 16 : 0),
                  child: Text(AppStrings.fadenAlternativesTitle, style: caption),
                ),
                for (final i in alternatives)
                  _AlternativeRow(
                    key: ValueKey('faden-alternative-$i'),
                    tokens: tokens,
                    passage: _session.passageLabel(leiter[i]),
                    beforeStop: _session.beforeStopLabel(leiter[i]),
                    playing: i == controller.leiterIndex,
                    onTap: () => unawaited(_session.resumeAtLeiterIndex(i)),
                  ),
              ],
            ],
          ),
        ),
        // "Fertig" as a full-width capsule at the thumb (E76); with the
        // night colours only its outline (no lit surface).
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 16),
          child: FilledButton(onPressed: _done, child: Text(AppStrings.fadenDone)),
        ),
      ],
    );
  }
}

/// [text] with its first sentence (up to ". ") in bold.
TextSpan _firstSentenceBold(String text) {
  final end = text.indexOf('. ');
  if (end < 0) return TextSpan(text: text);
  return TextSpan(
    children: [
      TextSpan(text: text.substring(0, end + 1), style: const TextStyle(fontWeight: FontWeight.w700)),
      TextSpan(text: text.substring(end + 1)),
    ],
  );
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
            // The answer under the passage: "kannte ich nicht" is long.
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(passage, style: TextStyle(fontSize: FadenTypeSizes.body, color: tokens.tinte)),
                  Text(answer, style: TextStyle(fontSize: FadenTypeSizes.caption, color: tokens.tinteLeise)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Nochmal prüfen" (E91): the earliest passage not recognised after
/// the result, to be asked once more.
class _RecheckRow extends StatelessWidget {
  final FadenTokens tokens;
  final String passage;
  final String beforeStop;
  final VoidCallback onTap;

  const _RecheckRow({
    super.key,
    required this.tokens,
    required this.passage,
    required this.beforeStop,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: fadenMinTapTarget),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Icon(Icons.replay, size: 20, color: tokens.faden),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(AppStrings.fadenRecheck, style: TextStyle(fontSize: FadenTypeSizes.body, color: tokens.faden)),
                      Text(
                        '$passage · $beforeStop',
                        style: TextStyle(fontSize: FadenTypeSizes.caption, color: tokens.tinteLeise),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
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
