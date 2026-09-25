import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/cellular_downloads.dart';
import '../l10n/strings.dart';
import 'controls.dart';
import 'format.dart';
import 'providers.dart';
import 'theme.dart';

/// The listener's answer to [CellularPromptDialog].
typedef CellularAnswer = ({bool load, bool dontShowAgain});

/// "Über Mobilfunk laden?" (decision E66) with the book's real estimate
/// ("1 Std. ≈ 58 MB · Kapitel 3 ≈ 24 MB"), "Nicht wieder anzeigen" and
/// "Laden" / "Nicht jetzt". In the app's look, day or night.
Future<CellularAnswer?> showCellularPromptDialog(BuildContext context, CellularEstimate estimate) =>
    showAdaptiveDialog<CellularAnswer>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CellularPromptDialog(estimate: estimate),
    );

class CellularPromptDialog extends StatefulWidget {
  final CellularEstimate estimate;

  const CellularPromptDialog({super.key, required this.estimate});

  @override
  State<CellularPromptDialog> createState() => _CellularPromptDialogState();
}

class _CellularPromptDialogState extends State<CellularPromptDialog> {
  bool _dontShowAgain = false;

  @override
  Widget build(BuildContext context) {
    final tokens = FadenTokens.of(context);
    final estimate = widget.estimate;
    final text = formatCellularEstimate(
      bytesPerHour: estimate.bytesPerHour,
      chapterNumber: estimate.chapterNumber,
      chapterBytes: estimate.chapterBytes,
      approximate: estimate.approximate,
    );
    // Night colours stay a ring (E65): no filled box on black.
    final checkbox = Checkbox.adaptive(
      value: _dontShowAgain,
      onChanged: (v) => setState(() => _dontShowAgain = v ?? false),
      activeColor: tokens.isDark ? Colors.transparent : tokens.faden,
      checkColor: tokens.isDark ? tokens.faden : tokens.grund,
      side: BorderSide(color: tokens.isDark ? tokens.faden : tokens.tinteLeise, width: 1.5),
    );
    return AlertDialog.adaptive(
      title: Text(AppStrings.cellularPromptTitle),
      content: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(AppStrings.cellularPromptBody),
            const SizedBox(height: 8),
            Text(
              text,
              style: TextStyle(
                color: tokens.tinte,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 8),
            MergeSemantics(
              child: InkWell(
                onTap: () => setState(() => _dontShowAgain = !_dontShowAgain),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: fadenMinTapTarget),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      checkbox,
                      const SizedBox(width: 4),
                      Flexible(child: Text(AppStrings.cellularPromptDontShowAgain)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        adaptiveDialogAction(
          context,
          text: AppStrings.cellularPromptNotNow,
          onPressed: () => Navigator.of(context).pop((load: false, dontShowAgain: false)),
        ),
        adaptiveDialogAction(
          context,
          text: AppStrings.cellularPromptLoad,
          onPressed: () => Navigator.of(context).pop((load: true, dontShowAgain: _dontShowAgain)),
        ),
      ],
    );
  }
}

/// Shows the question the [ChapterDownloader] waits on (decision E66),
/// only while the app is in the foreground and not over the Faden screen;
/// in the background nothing starts until it was answered. Sits above the
/// navigator (main.dart's `MaterialApp.builder`) and shows the dialog
/// through [navigatorKey].
class CellularPromptHost extends ConsumerStatefulWidget {
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  const CellularPromptHost({super.key, required this.navigatorKey, required this.child});

  @override
  ConsumerState<CellularPromptHost> createState() => _CellularPromptHostState();
}

class _CellularPromptHostState extends ConsumerState<CellularPromptHost> {
  ChapterDownloader? _downloader;
  AppLifecycleListener? _lifecycle;
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(_onResume()));
  }

  @override
  void dispose() {
    _downloader?.prompt.removeListener(_onPrompt);
    _lifecycle?.dispose();
    super.dispose();
  }

  void _attach(ChapterDownloader? downloader) {
    if (identical(downloader, _downloader)) return;
    _downloader?.prompt.removeListener(_onPrompt);
    _downloader = downloader;
    downloader?.prompt.addListener(_onPrompt);
    if (downloader?.prompt.value != null) WidgetsBinding.instance.addPostFrameCallback((_) => _onPrompt());
  }

  void _onPrompt() => unawaited(_maybeShow());

  Future<void> _onResume() async {
    // Back in front: look again (the book may have moved on meanwhile).
    await _downloader?.trigger();
    await _maybeShow();
  }

  static bool get _inForeground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  Future<void> _maybeShow() async {
    final downloader = _downloader;
    final prompt = downloader?.prompt.value;
    if (_showing || !mounted || downloader == null || prompt == null) return;
    if (!_inForeground || ref.read(fadenScreenOpenProvider)) return;
    final context = widget.navigatorKey.currentContext;
    if (context == null) return;
    _showing = true;
    try {
      final answer = await showCellularPromptDialog(context, prompt.estimate);
      await downloader.answer(load: answer?.load ?? false, dontShowAgain: answer?.dontShowAgain ?? false);
      if (mounted && (answer?.dontShowAgain ?? false)) ref.invalidate(cellularHintSettingProvider);
    } finally {
      _showing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    _attach(ref.watch(chapterDownloaderProvider));
    ref.listen<bool>(fadenScreenOpenProvider, (_, open) {
      if (!open) unawaited(_maybeShow());
    });
    return widget.child;
  }
}
