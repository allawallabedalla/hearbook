import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
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
  /// library: it closes the player (E60).
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
/// Zeitleiste mit Scrubber, Tempo, Sleep-Timer, Verlauf." The sleep timer
/// is one row that opens the moon button's own choice (decision E65), so
/// there is one sleep-timer UI, not two. Themed from
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

/// The sleep-timer choice (decision E61): 15, 30, 45, 60 Min., Kapitelende,
/// Aus. Opened by the player's moon button and by the details sheet's
/// sleep-timer row (E65) -- the one sleep-timer UI. Themed from [chrome]
/// like the details sheet, acting on the shared [sleepTimer]. A choice
/// starts (or stops) the timer and closes the sheet; the chosen duration
/// is also what a headphone button in the last minute extends by.
/// Nothing is preselected and no default is stored (decision E67).
Future<void> showSleepTimerSheet(
  BuildContext context, {
  required ValueListenable<PlayerChrome> chrome,
  required SleepTimerController sleepTimer,
  DetailsSheetHooks hooks = const DetailsSheetHooks(),
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    elevation: 0,
    builder: (_) => _SheetFrame(
      chrome: chrome,
      hooks: hooks,
      child: SleepTimerChoices(controller: sleepTimer),
    ),
  );
}

/// The rows of [showSleepTimerSheet]; the running choice is marked.
class SleepTimerChoices extends StatelessWidget {
  final SleepTimerController controller;
  const SleepTimerChoices({super.key, required this.controller});

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

        Widget choice(String label, {required bool selected, required VoidCallback onTap}) => ListTile(
              contentPadding: EdgeInsets.zero,
              selected: selected,
              selectedColor: tokens.faden,
              title: Text(label),
              trailing: selected ? Icon(Icons.check, color: tokens.faden) : null,
              onTap: () {
                unawaited(HapticFeedback.selectionClick());
                onTap();
                Navigator.of(context).pop();
              },
            );

        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 5,
                  decoration: BoxDecoration(color: tokens.tinteLeiseFaden, borderRadius: BorderRadius.circular(3)),
                ),
              ),
              const SizedBox(height: 12),
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
              for (final minutes in sleepTimerPresetMinutes)
                choice(
                  AppStrings.sleepTimerMinutes(minutes),
                  selected: chosenMin == minutes,
                  onTap: () {
                    controller.start(Duration(minutes: minutes));
                  },
                ),
              choice(
                AppStrings.sleepTimerChapterEnd,
                selected: chapterEnd,
                onTap: () {
                  // Fires when playback actually reaches the next chapter (E42).
                  controller.startChapterEnd();
                },
              ),
              choice(AppStrings.sleepTimerOff, selected: !state.running, onTap: controller.cancel),
            ],
          ),
        );
      },
    );
  }
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
        // Dimmed like the night player's title (E65).
        ValueListenableBuilder<PlayerChrome>(
          valueListenable: chrome,
          builder: (context, c, _) =>
              ChapterScrubber(manifest: manifest, handler: handler, initial: initial, night: c.night),
        ),
        const SizedBox(height: 28),
        SectionTitle(AppStrings.detailsSpeed),
        SpeedControl(handler: handler, onSelected: session.setSpeed),
        if (sleepTimer != null) ...[
          const SizedBox(height: 20),
          SleepTimerRow(
            controller: sleepTimer!,
            onTap: () => unawaited(
              showSleepTimerSheet(
                context,
                chrome: chrome,
                sleepTimer: sleepTimer!,
                hooks: DetailsSheetHooks(onInteraction: hooks.onInteraction),
              ),
            ),
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
                unawaited(HapticFeedback.lightImpact());
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

/// Scrubber for the current chapter, in the details sheet and on the
/// player (E59): elapsed and remaining time, a large readout while
/// dragging, and a journaled seek on release (the handler's
/// `seekToGlobalMs`, so a jump over 2 min still produces the undo hint).
/// Track, thumb and time labels share the left and right edges of the
/// thread above (E65). In the night view ([night]) the chapter line is
/// dimmed like the book title.
class ChapterScrubber extends StatefulWidget {
  final Manifest manifest;
  final FadenAudioHandler handler;
  final Position initial;
  final bool night;

  const ChapterScrubber({
    super.key,
    required this.manifest,
    required this.handler,
    required this.initial,
    this.night = false,
  });

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
    // Counting times keep their width (tabular figures), so the digits do
    // not jitter while playing or dragging.
    final time = small.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);

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
                    style: TextStyle(
                      color: widget.night ? tokens.tinteLeise : tokens.tinte,
                      fontSize: FadenTypeSizes.body,
                    ),
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
        // VoiceOver: "Position im Kapitel, 7:00" -- one element.
        MergeSemantics(
          child: Semantics(
          label: AppStrings.scrubberLabel,
          child: Slider(
            value: offset,
            max: duration.toDouble(),
            label: formatClock(offset.round()),
            // No side inset: the track runs edge to edge like the thread
            // and the time labels (E65); the height stays a tap target.
            padding: const EdgeInsets.symmetric(vertical: 14),
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
        ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(formatClock(offset.round()), style: time),
            Text(AppStrings.scrubberRemaining(formatClock(duration - offset.round())), style: time),
          ],
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

/// What a running sleep timer shows (decision E61): the minutes left,
/// rounded up ("12 Min."), or "Kapitelende". Null while no timer runs.
/// The moon button and the details sheet's row say the same (E65).
String? sleepTimerButtonText(SleepTimerState state) {
  if (!state.running) return null;
  if (state.mode == SleepTimerMode.chapterEnd) return AppStrings.sleepTimerChapterEnd;
  final minutes = (state.remaining.inSeconds + 59) ~/ 60;
  return AppStrings.sleepTimerMinutes(minutes < 1 ? 1 : minutes);
}

/// The details sheet's sleep timer (decision E65): one row, "Sleep-Timer
/// · 12 Min. ›" (or "Aus"), that opens the same choice as the player's
/// moon button ([showSleepTimerSheet]).
class SleepTimerRow extends StatelessWidget {
  final SleepTimerController controller;
  final VoidCallback onTap;

  const SleepTimerRow({super.key, required this.controller, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = FadenTokens.of(context);
    return StreamBuilder<SleepTimerState>(
      stream: controller.stateStream,
      initialData: controller.state,
      builder: (context, snap) {
        final running = sleepTimerButtonText(snap.data ?? controller.state);
        final value = running ?? AppStrings.sleepTimerOff;
        return Semantics(
          button: true,
          label: AppStrings.detailsSleepTimer,
          value: value,
          excludeSemantics: true,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            minTileHeight: fadenMinTapTarget,
            // Reads as a heading like "Tempo" above it (E97).
            title: Text(
              AppStrings.detailsSleepTimer,
              style: TextStyle(color: tokens.tinte, fontSize: FadenTypeSizes.title, fontWeight: fadenHeadingWeight),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    color: running == null ? tokens.tinteLeise : tokens.faden,
                    fontSize: FadenTypeSizes.body,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.chevron_right, color: tokens.tinteLeise),
              ],
            ),
            onTap: onTap,
          ),
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
    // "Kapitel 3 · 23:41" like the undo hint and the Faden search's
    // passages (E97), the chapter's own title below it.
    final chapter = idx >= 0 ? AppStrings.chapterLabel(idx + 1) : '';
    final title = idx >= 0 ? manifest.files[idx].displayTitle(chapter) : chapter;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        AppStrings.fadenPassage(chapter, formatClock(position.offsetMs)),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
      ),
      subtitle: title == chapter ? null : Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
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
