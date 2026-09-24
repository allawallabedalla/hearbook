import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/handler.dart';
import '../domain/manifest.dart';
import '../domain/position.dart';
import '../domain/resolver.dart' show BookState;
import '../l10n/strings.dart';
import '../signals/sleep_timer.dart';
import 'providers.dart';
import 'theme.dart';

/// docs/KONZEPT.md "Screens": "2. Details (nach oben wischen): Kapitel,
/// Zeitleiste mit Scrubber, Tempo, Sleep-Timer, Verlauf."
Future<void> showDetailsSheet(BuildContext context, {SleepTimerController? sleepTimer}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).scaffoldBackgroundColor,
    builder: (context) => DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) =>
          DetailsSheetContent(scrollController: scrollController, sleepTimer: sleepTimer),
    ),
  );
}

class DetailsSheetContent extends ConsumerWidget {
  final ScrollController scrollController;
  final SleepTimerController? sleepTimer;

  const DetailsSheetContent({super.key, required this.scrollController, this.sleepTimer});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(playerSessionProvider);
    final tokens = FadenTokens.of(context);
    final manifest = session.manifest;
    final bookState = session.bookState;
    if (manifest == null || bookState == null) return const SizedBox.shrink();
    final handler = ref.watch(audioHandlerProvider);

    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      children: [
        Center(
          child: Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(color: tokens.tinteLeise, borderRadius: BorderRadius.circular(2)),
          ),
        ),
        const SizedBox(height: 24),
        _Scrubber(manifest: manifest, bookState: bookState, handler: handler, tokens: tokens),
        const SizedBox(height: 24),
        Text(AppStrings.detailsSpeed, style: TextStyle(fontSize: FadenTypeSizes.title, color: tokens.tinte)),
        const SizedBox(height: 8),
        _SpeedControl(handler: handler, tokens: tokens),
        const SizedBox(height: 24),
        Text(AppStrings.detailsSleepTimer,
            style: TextStyle(fontSize: FadenTypeSizes.title, color: tokens.tinte)),
        const SizedBox(height: 8),
        if (sleepTimer != null)
          _SleepTimerControl(
            controller: sleepTimer!,
            tokens: tokens,
            manifest: manifest,
            handler: handler,
          ),
        const SizedBox(height: 24),
        Text(AppStrings.detailsChapters,
            style: TextStyle(fontSize: FadenTypeSizes.title, color: tokens.tinte)),
        const SizedBox(height: 8),
        for (var i = 0; i < manifest.files.length; i++)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(AppStrings.chapterLabel(i + 1), style: TextStyle(color: tokens.tinte)),
            onTap: () {
              handler.seekToChapterStart(i);
              Navigator.of(context).pop();
            },
          ),
        if (bookState.history.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text(AppStrings.detailsHistory,
              style: TextStyle(fontSize: FadenTypeSizes.title, color: tokens.tinte)),
          const SizedBox(height: 8),
          for (final position in bookState.history)
            _HistoryRow(
              position: position,
              manifest: manifest,
              tokens: tokens,
              onTap: () {
                handler.undo(position);
                Navigator.of(context).pop();
              },
            ),
        ],
      ],
    );
  }
}

class _Scrubber extends StatefulWidget {
  final Manifest manifest;
  final BookState bookState;
  final FadenAudioHandler handler;
  final FadenTokens tokens;

  const _Scrubber({
    required this.manifest,
    required this.bookState,
    required this.handler,
    required this.tokens,
  });

  @override
  State<_Scrubber> createState() => _ScrubberState();
}

class _ScrubberState extends State<_Scrubber> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Position>(
      stream: widget.handler.positionStream,
      initialData: widget.bookState.position,
      builder: (context, snap) {
        final pos = snap.data ?? widget.bookState.position;
        final total = widget.manifest.totalDurationMs;
        final globalMs = widget.manifest.globalMsFor(pos) ?? 0;
        final value = (_dragValue ?? globalMs.toDouble()).clamp(0.0, total.toDouble());
        return Column(
          children: [
            Slider(
              value: value,
              min: 0,
              max: total.toDouble() <= 0 ? 1 : total.toDouble(),
              onChanged: (v) => setState(() => _dragValue = v),
              onChangeEnd: (v) {
                widget.handler.seekToGlobalMs(v.round());
                setState(() => _dragValue = null);
              },
            ),
          ],
        );
      },
    );
  }
}

class _SpeedControl extends StatelessWidget {
  static const speeds = [0.75, 1.0, 1.25, 1.5, 2.0];

  final FadenAudioHandler handler;
  final FadenTokens tokens;

  const _SpeedControl({required this.handler, required this.tokens});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<double>(
      stream: handler.speedStream,
      initialData: handler.speed,
      builder: (context, snap) {
        final current = snap.data ?? 1.0;
        return Wrap(
          spacing: 8,
          children: [
            for (final speed in speeds)
              ChoiceChip(
                label: Text('${speed}x'),
                selected: (current - speed).abs() < 0.01,
                onSelected: (_) => handler.setSpeed(speed),
              ),
          ],
        );
      },
    );
  }
}

class _SleepTimerControl extends StatelessWidget {
  final SleepTimerController controller;
  final FadenTokens tokens;
  final Manifest manifest;
  final FadenAudioHandler handler;

  const _SleepTimerControl({
    required this.controller,
    required this.tokens,
    required this.manifest,
    required this.handler,
  });

  /// Remaining time until the end of the chapter [pos] is in
  /// (docs/KONZEPT.md "Nachtmodus": "... oder Kapitelende").
  Duration _remainingInChapter(Position pos) {
    final idx = manifest.files.indexWhere((f) => f.fileHash == pos.fileHash);
    if (idx == -1) return const Duration(minutes: 30); // needs_confirmation fallback
    final chapterDurationMs = manifest.files[idx].durationMs;
    final remainingMs = (chapterDurationMs - pos.offsetMs).clamp(0, chapterDurationMs);
    return Duration(milliseconds: remainingMs);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SleepTimerState>(
      stream: controller.stateStream,
      initialData: controller.state,
      builder: (context, snap) {
        final state = snap.data ?? controller.state;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final minutes in sleepTimerPresetMinutes)
              ChoiceChip(
                label: Text(AppStrings.sleepTimerMinutes(minutes)),
                selected: state.running && state.mode == SleepTimerMode.fixed && state.remaining.inMinutes + 1 >= minutes && state.remaining.inMinutes <= minutes,
                onSelected: (_) => controller.start(Duration(minutes: minutes), mode: SleepTimerMode.fixed),
              ),
            ChoiceChip(
              label: Text(AppStrings.sleepTimerChapterEnd),
              selected: state.mode == SleepTimerMode.chapterEnd,
              onSelected: (_) =>
                  controller.start(_remainingInChapter(handler.currentPosition()), mode: SleepTimerMode.chapterEnd),
            ),
            if (state.running)
              ActionChip(
                label: Text(AppStrings.sleepTimerOff),
                onPressed: controller.cancel,
              ),
            if (state.running)
              Text(
                '${state.remaining.inMinutes}:${(state.remaining.inSeconds % 60).toString().padLeft(2, '0')}',
                style: TextStyle(color: tokens.tinteLeise),
              ),
          ],
        );
      },
    );
  }
}

class _HistoryRow extends StatelessWidget {
  final Position position;
  final Manifest manifest;
  final FadenTokens tokens;
  final VoidCallback onTap;

  const _HistoryRow({
    required this.position,
    required this.manifest,
    required this.tokens,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final idx = manifest.files.indexWhere((f) => f.fileHash == position.fileHash);
    final label = idx >= 0 ? AppStrings.chapterLabel(idx + 1) : '';
    final seconds = position.offsetMs ~/ 1000;
    final mmss = '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text('$label · $mmss', style: TextStyle(color: tokens.tinte)),
      trailing: Icon(Icons.undo, color: tokens.tinteLeise),
      onTap: onTap,
    );
  }
}
