import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/handler.dart';
import '../domain/manifest.dart';
import '../domain/position.dart';
import '../l10n/strings.dart';
import '../signals/sleep_timer.dart';
import 'controls.dart';
import 'format.dart';
import 'providers.dart';
import 'theme.dart';

/// How the player looks right now, handed to the sheets it opens
/// (decision E46). A sheet is its own route, built above the player's
/// `Theme`; without this it came up in the day colours at night.
@immutable
class PlayerChrome {
  final ThemeData theme;
  final bool night;

  const PlayerChrome({required this.theme, required this.night});

  FadenTokens get tokens => theme.extension<FadenTokens>() ?? FadenTokens.day;

  @override
  bool operator ==(Object other) => other is PlayerChrome && other.theme == theme && other.night == night;

  @override
  int get hashCode => Object.hash(theme, night);
}

/// Callbacks from the sheet back into the player screen.
class DetailsSheetHooks {
  /// Any touch in the sheet counts like a touch on the player: an
  /// awake-proof (AWAKE, docs/ARCHITEKTUR.md section 9).
  final VoidCallback onInteraction;

  /// The night player has no app bar, so the sheet is its way to the
  /// library.
  final VoidCallback? onOpenLibrary;

  const DetailsSheetHooks({
    this.onInteraction = _noop,
    this.onOpenLibrary,
  });

  static void _noop() {}
}

/// Key of the sheet's background surface (tests read its colour).
const detailsSheetSurfaceKey = ValueKey('details-sheet-surface');

/// docs/KONZEPT.md "Screens": "2. Details (nach oben wischen): Kapitel,
/// Zeitleiste mit Scrubber, Tempo, Sleep-Timer, Verlauf." Themed from
/// [chrome] for as long as it is open, so it turns dark the moment the
/// night view starts (the display is dimmed below 30 %, E54).
Future<void> showDetailsSheet(
  BuildContext context, {
  required ValueListenable<PlayerChrome> chrome,
  SleepTimerController? sleepTimer,
  DetailsSheetHooks hooks = const DetailsSheetHooks(),
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    // Drawn by _SheetFrame, which follows [chrome]; the route's own
    // colour would be fixed at the moment the sheet opened.
    backgroundColor: Colors.transparent,
    elevation: 0,
    builder: (_) => _SheetFrame(
      chrome: chrome,
      hooks: hooks,
      child: DraggableScrollableSheet(
        initialChildSize: 0.8,
        minChildSize: 0.4,
        maxChildSize: 1,
        expand: false,
        builder: (context, scrollController) => DetailsSheetContent(
          scrollController: scrollController,
          sleepTimer: sleepTimer,
          chrome: chrome,
          hooks: hooks,
        ),
      ),
    ),
  );
}

/// Background, theme and touch forwarding shared by the details sheet and
/// the chapter list.
class _SheetFrame extends StatelessWidget {
  final ValueListenable<PlayerChrome> chrome;
  final DetailsSheetHooks hooks;
  final Widget child;

  const _SheetFrame({required this.chrome, required this.hooks, required this.child});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PlayerChrome>(
      valueListenable: chrome,
      child: child,
      builder: (context, c, child) {
        final tokens = c.tokens;
        return Theme(
          data: c.theme,
          child: Listener(
            onPointerDown: (_) => hooks.onInteraction(),
            // A Material (not a plain box) so list tiles and buttons in the
            // sheet draw their pressed state on it.
            child: Material(
              key: detailsSheetSurfaceKey,
              color: tokens.grund,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                side: BorderSide(color: tokens.linie, width: 0.5),
              ),
              child: child,
            ),
          ),
        );
      },
    );
  }
}

class DetailsSheetContent extends ConsumerWidget {
  final ScrollController scrollController;
  final SleepTimerController? sleepTimer;
  final ValueListenable<PlayerChrome> chrome;
  final DetailsSheetHooks hooks;

  const DetailsSheetContent({
    super.key,
    required this.scrollController,
    required this.chrome,
    this.sleepTimer,
    this.hooks = const DetailsSheetHooks(),
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(playerSessionProvider);
    final tokens = FadenTokens.of(context);
    final manifest = session.manifest;
    final bookState = session.bookState;
    if (manifest == null || bookState == null) return const SizedBox.shrink();
    final handler = ref.watch(audioHandlerProvider);
    final initial = livePosition(handler, session);
    final onOpenLibrary = hooks.onOpenLibrary;

    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        Center(
          child: Container(
            width: 36,
            height: 5,
            decoration: BoxDecoration(color: tokens.tinteLeiseFaden, borderRadius: BorderRadius.circular(3)),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(
                session.bookTitle ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: tokens.tinteLeise, fontSize: FadenTypeSizes.caption),
              ),
            ),
            if (onOpenLibrary != null)
              TextButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  onOpenLibrary();
                },
                icon: const Icon(Icons.menu_book_outlined, size: 20),
                label: Text(AppStrings.libraryTitle),
              ),
          ],
        ),
        const SizedBox(height: 8),
        ChapterScrubber(manifest: manifest, handler: handler, initial: initial),
        const SizedBox(height: 28),
        SectionTitle(AppStrings.detailsSpeed),
        SpeedControl(handler: handler, onSelected: session.setSpeed),
        if (sleepTimer != null) ...[
          const SizedBox(height: 28),
          SleepTimerControl(
            controller: sleepTimer!,
            defaultMinutes: ref.watch(sleepTimerDefaultProvider).value ?? 30,
            onChosen: (minutes) => ref.read(sleepTimerDefaultProvider.notifier).set(minutes),
          ),
        ],
        if (bookState.history.isNotEmpty) ...[
          const SizedBox(height: 28),
          SectionTitle(AppStrings.detailsHistory),
          for (final position in bookState.history)
            _HistoryRow(
              position: position,
              manifest: manifest,
              onTap: () {
                // UNDO event (invariant 6), journaled by the handler.
                unawaited(handler.undo(position));
                Navigator.of(context).pop();
              },
            ),
        ],
        const SizedBox(height: 28),
        SectionTitle(AppStrings.detailsChapters),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(AppStrings.detailsAllChapters(manifest.files.length)),
          trailing: Icon(Icons.chevron_right, color: tokens.tinteLeise),
          onTap: () => _openChapters(context, manifest, handler, initial),
        ),
      ],
    );
  }

  Future<void> _openChapters(
    BuildContext context,
    Manifest manifest,
    FadenAudioHandler handler,
    Position position,
  ) async {
    final current = manifest.indexOf(handler.currentPosition().fileHash);
    final chosen = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      elevation: 0,
      builder: (context) => _SheetFrame(
        chrome: chrome,
        hooks: hooks,
        child: ChapterList(manifest: manifest, currentIndex: current >= 0 ? current : manifest.indexOf(position.fileHash)),
      ),
    );
    if (chosen == null) return;
    // A journaled SEEK with the undo hint for a jump over 2 min.
    unawaited(handler.seekToChapterStart(chosen));
    if (context.mounted) Navigator.of(context).pop();
  }
}

/// Where playback stands now: the handler's live position when it has the
/// open book loaded, otherwise the resolved one.
Position livePosition(FadenAudioHandler handler, PlayerSessionController session) {
  final state = session.bookState;
  if (handler.bookId == session.bookId) {
    final live = handler.currentPosition();
    if (live.fileHash.isNotEmpty) return live;
  }
  return state?.position ?? const Position(fileHash: '', offsetMs: 0);
}

/// Scrubber for the current chapter (docs/KONZEPT.md: the scrubber lives
/// here, not on the player): elapsed and remaining time, a large readout
/// while dragging, and a journaled seek on release (the handler's
/// `seekToGlobalMs`, so a jump over 2 min still produces the undo hint).
class ChapterScrubber extends StatefulWidget {
  final Manifest manifest;
  final FadenAudioHandler handler;
  final Position initial;

  const ChapterScrubber({super.key, required this.manifest, required this.handler, required this.initial});

  @override
  State<ChapterScrubber> createState() => _ChapterScrubberState();
}

class _ChapterScrubberState extends State<ChapterScrubber> {
  late Position _pos = widget.initial;
  StreamSubscription<Position>? _sub;
  double? _dragMs;

  @override
  void initState() {
    super.initState();
    _sub = widget.handler.positionStream.listen((p) {
      if (mounted) setState(() => _pos = p);
    });
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = FadenTokens.of(context);
    final files = widget.manifest.files;
    if (files.isEmpty) return const SizedBox.shrink();
    var idx = widget.manifest.indexOf(_pos.fileHash);
    if (idx < 0) idx = 0;
    final file = files[idx];
    final duration = file.durationMs <= 0 ? 1 : file.durationMs;
    final offset = (_dragMs ?? _pos.offsetMs.toDouble()).clamp(0.0, duration.toDouble());
    final dragging = _dragMs != null;
    final small = TextStyle(color: tokens.tinteLeise, fontSize: FadenTypeSizes.caption);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            Visibility.maintain(
              visible: !dragging,
              child: Column(
                children: [
                  Text(
                    file.displayTitle(AppStrings.chapterLabel(idx + 1)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: tokens.tinte, fontSize: FadenTypeSizes.body),
                  ),
                  Text(AppStrings.chapterOfTotal(idx + 1, files.length), style: small),
                ],
              ),
            ),
            Visibility.maintain(
              visible: dragging,
              child: Text(
                formatClock(offset.round()),
                style: TextStyle(
                  color: tokens.faden,
                  fontSize: FadenTypeSizes.display,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
        Slider(
          value: offset,
          max: duration.toDouble(),
          label: formatClock(offset.round()),
          semanticFormatterCallback: (v) => formatClock(v.round()),
          onChangeStart: (v) => setState(() => _dragMs = v),
          onChanged: (v) => setState(() => _dragMs = v),
          onChangeEnd: (v) {
            final start = widget.manifest.fileStartMs(file.fileHash) ?? 0;
            unawaited(widget.handler.seekToGlobalMs(start + v.round()));
            setState(() {
              _pos = Position(fileHash: file.fileHash, offsetMs: v.round());
              _dragMs = null;
            });
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(formatClock(offset.round()), style: small),
              Text(AppStrings.scrubberRemaining(formatClock(duration - offset.round())), style: small),
            ],
          ),
        ),
      ],
    );
  }
}

/// "Tempo" (E38: stored per book).
class SpeedControl extends StatelessWidget {
  static const speeds = [0.75, 1.0, 1.25, 1.5, 2.0];

  final FadenAudioHandler handler;
  final Future<void> Function(double speed) onSelected;

  const SpeedControl({super.key, required this.handler, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<double>(
      stream: handler.speedStream,
      initialData: handler.speed,
      builder: (context, snap) {
        final current = snap.data ?? 1.0;
        final selected = speeds.where((s) => (s - current).abs() < 0.01).firstOrNull;
        return FadenSegmented<double>(
          values: speeds,
          selected: selected,
          label: formatSpeed,
          onChanged: (speed) => unawaited(onSelected(speed)),
        );
      },
    );
  }
}

/// Sleep timer: presets, "Kapitelende", the running countdown, "Aus", and
/// a quick start with the stored default (E42).
class SleepTimerControl extends StatelessWidget {
  final SleepTimerController controller;

  /// Stored default in minutes, 0 = "Kapitelende".
  final int defaultMinutes;

  /// Remembers the choice as the default (minutes, 0 = "Kapitelende").
  final void Function(int minutes) onChosen;

  const SleepTimerControl({
    super.key,
    required this.controller,
    required this.defaultMinutes,
    required this.onChosen,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = FadenTokens.of(context);
    return StreamBuilder<SleepTimerState>(
      stream: controller.stateStream,
      initialData: controller.state,
      builder: (context, snap) {
        final state = snap.data ?? controller.state;
        final chapterEnd = state.running && state.mode == SleepTimerMode.chapterEnd;
        final chosenMin = state.running ? state.chosen?.inMinutes : null;
        final status = !state.running
            ? null
            : chapterEnd
                ? AppStrings.sleepTimerUntilChapterEnd(formatClock(state.remaining.inMilliseconds))
                : AppStrings.sleepTimerRunning(formatClock(state.remaining.inMilliseconds));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionTitle(
              AppStrings.detailsSleepTimer,
              trailing: status == null
                  ? null
                  : Text(
                      status,
                      style: TextStyle(
                        color: tokens.faden,
                        fontSize: FadenTypeSizes.caption,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
            ),
            FadenSegmented<int>(
              values: sleepTimerPresetMinutes,
              selected: chosenMin,
              label: AppStrings.sleepTimerMinutes,
              onChanged: (minutes) {
                controller.start(Duration(minutes: minutes));
                onChosen(minutes);
              },
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FadenSegmented<int>(
                    values: const [0],
                    selected: chapterEnd ? 0 : null,
                    label: (_) => AppStrings.sleepTimerChapterEnd,
                    onChanged: (_) {
                      // Fires when playback actually reaches the next chapter (E42).
                      controller.startChapterEnd();
                      onChosen(0);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: state.running
                      ? OutlinedButton(
                          onPressed: controller.cancel,
                          child: Text(AppStrings.sleepTimerOff),
                        )
                      : FilledButton(
                          onPressed: () => controller.startWithDefault(defaultMinutes),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              AppStrings.sleepTimerStart(
                                defaultMinutes <= 0
                                    ? AppStrings.sleepTimerChapterEnd
                                    : AppStrings.sleepTimerMinutes(defaultMinutes),
                              ),
                            ),
                          ),
                        ),
                ),
              ],
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
  final VoidCallback onTap;

  const _HistoryRow({required this.position, required this.manifest, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = FadenTokens.of(context);
    final idx = manifest.indexOf(position.fileHash);
    final label = idx >= 0 ? manifest.files[idx].displayTitle(AppStrings.chapterLabel(idx + 1)) : '';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text('$label · ${formatClock(position.offsetMs)}', maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Icon(Icons.undo, color: tokens.tinteLeise, semanticLabel: AppStrings.undoAction),
      onTap: onTap,
    );
  }
}

/// All chapters with their real titles and durations; the current one is
/// highlighted and scrolled into view. Pops with the chosen index.
class ChapterList extends StatefulWidget {
  final Manifest manifest;
  final int currentIndex;

  const ChapterList({super.key, required this.manifest, required this.currentIndex});

  @override
  State<ChapterList> createState() => _ChapterListState();
}

class _ChapterListState extends State<ChapterList> {
  ScrollController? _controller;

  double _rowExtent(BuildContext context) => MediaQuery.textScalerOf(context).scale(FadenTypeSizes.body) * 1.25 + 38;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Two rows of context above the current chapter.
    _controller ??= ScrollController(
      initialScrollOffset: ((widget.currentIndex - 2).clamp(0, widget.manifest.files.length) * _rowExtent(context)),
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = FadenTokens.of(context);
    final files = widget.manifest.files;
    final extent = _rowExtent(context);
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.85,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          Center(
            child: Container(
              width: 36,
              height: 5,
              decoration: BoxDecoration(color: tokens.tinteLeiseFaden, borderRadius: BorderRadius.circular(3)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: SectionTitle(AppStrings.detailsChapters),
          ),
          Expanded(
            child: ListView.builder(
              controller: _controller,
              itemExtent: extent,
              itemCount: files.length,
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              itemBuilder: (context, i) {
                final current = i == widget.currentIndex;
                final color = current ? tokens.faden : tokens.tinte;
                return Semantics(
                  selected: current,
                  button: true,
                  child: InkWell(
                    onTap: () => Navigator.of(context).pop(i),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 28,
                          child: current
                              ? Icon(Icons.graphic_eq, size: 18, color: tokens.faden)
                              : Text('${i + 1}', style: TextStyle(color: tokens.tinteLeise, fontSize: FadenTypeSizes.caption)),
                        ),
                        Expanded(
                          child: Text(
                            files[i].displayTitle(AppStrings.chapterLabel(i + 1)),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: color,
                              fontSize: FadenTypeSizes.body,
                              fontWeight: current ? FontWeight.w700 : FontWeight.w400,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          formatClock(files[i].durationMs),
                          style: TextStyle(
                            color: tokens.tinteLeise,
                            fontSize: FadenTypeSizes.caption,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
