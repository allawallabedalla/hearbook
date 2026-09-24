import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' as ja;

import '../audio/probe_player.dart';
import '../domain/faden_search.dart' as fs;
import '../domain/manifest.dart';
import '../l10n/strings.dart';
import 'faden_search_controller.dart';
import 'providers.dart';
import 'theme.dart';

/// docs/KONZEPT.md "Faden-Modus": "Vollbild, dunkel, siehe oben [Faden
/// aufnehmen]." Full-screen, always the night palette regardless of the
/// actual night window (the whole point is a calm, low-light search
/// screen), showing only the shrinking thread and the probe counter --
/// deliberately no cover, title, or transport controls (that is also what
/// lets audio/handler.dart treat every hardware media-button call received
/// while this screen is open as "kenne ich", see its `enterFadenMode` doc
/// comment).
class FadenScreen extends ConsumerStatefulWidget {
  final Manifest manifest;

  /// `last_awake`, global ms.
  final int lo;

  /// `stop`, global ms.
  final int hi;

  /// Sentence-start offsets, global ms (domain/pause_index.dart).
  final List<int> pausen;

  final List<ja.IndexedAudioSource> playlistSources;

  const FadenScreen({
    super.key,
    required this.manifest,
    required this.lo,
    required this.hi,
    required this.pausen,
    required this.playlistSources,
  });

  @override
  ConsumerState<FadenScreen> createState() => _FadenScreenState();
}

class _FadenScreenState extends ConsumerState<FadenScreen> {
  late final ProbePlayer _probePlayer;
  late final FadenSearchController _controller;
  StreamSubscription<void>? _mediaAnswerSub;
  FadenProgress? _progress;
  bool _found = false;

  @override
  void initState() {
    super.initState();
    final handler = ref.read(audioHandlerProvider);
    handler.enterFadenMode();

    _probePlayer = ProbePlayer();
    _probePlayer.open(widget.playlistSources);

    _mediaAnswerSub = handler.fadenModeAnswers.listen((_) => _controller.submitAnswer());

    _controller = FadenSearchController(
      lo: widget.lo,
      hi: widget.hi,
      pausen: widget.pausen,
      playTone: _probePlayer.playTone,
      playProbe: (p) {
        final pos = widget.manifest.positionForGlobalMs(p);
        final idx = widget.manifest.files.indexWhere((f) => f.fileHash == pos.fileHash);
        if (idx < 0) return Future.value();
        return _probePlayer.playProbe(fileIndex: idx, offsetMs: pos.offsetMs, probeLenMs: fs.probeLen);
      },
      stopProbe: _probePlayer.stop,
      onProbeAnswered: (p, known) {
        final pos = widget.manifest.positionForGlobalMs(p);
        return handler.probe(position: pos, known: known);
      },
      onResumeAt: _handleResolved,
      onAborted: _handleAborted,
    );
    _controller.progress.listen((p) {
      if (mounted) setState(() => _progress = p);
    });

    unawaited(_controller.start());
  }

  /// The search's own finding, or a later "Früher" step (both call
  /// [FadenSearchController.onResumeAt]): resume playback there and show
  /// the brief "Gefunden. Weiter ab hier." state (with "Früher" if the
  /// ladder allows going back further) instead of closing immediately --
  /// docs/KONZEPT.md's "Ergebnis"/"Leiter" texts need somewhere to appear.
  Future<void> _handleResolved(int globalMs) async {
    await _resumeTo(globalMs);
    if (mounted) setState(() => _found = true);
  }

  /// Long-press abort (docs/KONZEPT.md: "... startet am letzten sicheren
  /// Wach-Punkt."): resume there and close straight back to the player, no
  /// intermediate "Gefunden" state.
  Future<void> _handleAborted(int globalMs) async {
    await _resumeTo(globalMs);
    _closeToPlayer();
  }

  Future<void> _resumeTo(int globalMs) async {
    final pos = widget.manifest.positionForGlobalMs(globalMs);
    final idx = widget.manifest.files.indexWhere((f) => f.fileHash == pos.fileHash);
    await ref.read(audioHandlerProvider).resumeFromFaden(pos, fileIndex: idx < 0 ? null : idx);
  }

  void _closeToPlayer() {
    ref.read(audioHandlerProvider).exitFadenMode();
    Navigator.of(context).pop();
  }

  void _onTap() {
    if (_found) {
      _closeToPlayer();
      return;
    }
    _controller.submitAnswer();
  }

  void _onLongPress() {
    if (_found) return;
    _controller.abort();
  }

  Future<void> _onEarlier() async {
    await _controller.earlier();
  }

  @override
  void dispose() {
    _mediaAnswerSub?.cancel();
    _controller.dispose();
    unawaited(_probePlayer.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = FadenTokens.night;
    final theme = buildFadenTheme(tokens);
    final progress = _progress;
    final windowMs = widget.hi - widget.lo;
    final remainingMs = progress == null ? windowMs : (progress.hi - progress.lo);
    final fraction = windowMs <= 0 ? 0.0 : (remainingMs / windowMs).clamp(0.0, 1.0);

    return Theme(
      data: theme,
      child: Scaffold(
        backgroundColor: tokens.grund,
        body: SafeArea(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _onTap,
            onLongPress: _onLongPress,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: _found
                      ? _foundChildren(tokens)
                      : _searchingChildren(tokens, fraction, progress),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _searchingChildren(FadenTokens tokens, double fraction, FadenProgress? progress) {
    return [
      Text(
        AppStrings.fadenModePrompt,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: FadenTypeSizes.title, color: tokens.tinte),
      ),
      const SizedBox(height: 40),
      // docs/KONZEPT.md "Bewegung": "im Faden-Modus wird der Faden mit
      // jeder Antwort kürzer (300 ms)".
      ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
          height: 3,
          width: (MediaQuery.of(context).size.width - 64) * fraction,
          color: tokens.faden,
        ),
      ),
      const SizedBox(height: 24),
      Text(
        AppStrings.fadenProbeCounter(progress?.probeNr ?? 0, fs.maxProbes),
        style: TextStyle(fontSize: FadenTypeSizes.caption, color: tokens.tinteLeise),
      ),
    ];
  }

  List<Widget> _foundChildren(FadenTokens tokens) {
    return [
      Text(
        AppStrings.fadenResultFound,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: FadenTypeSizes.title, color: tokens.tinte),
      ),
      if (_controller.canGoEarlier) ...[
        const SizedBox(height: 24),
        TextButton(
          onPressed: _onEarlier,
          child: Text(
            AppStrings.fadenLadderEarlier,
            style: TextStyle(fontSize: FadenTypeSizes.body, color: tokens.faden),
          ),
        ),
      ],
    ];
  }
}
