import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import 'theme.dart';

/// A segmented choice in the token colours (decision E44): equal-width
/// segments, so a changed selection never moves or resizes anything (the
/// chips it replaces jumped in width with their check mark). Labels scale
/// down to fit rather than overflow at large text sizes. Height is the
/// 56 dp minimum tap target.
class FadenSegmented<T> extends StatelessWidget {
  final List<T> values;
  final T? selected;
  final String Function(T value) label;
  final ValueChanged<T>? onChanged;

  const FadenSegmented({
    super.key,
    required this.values,
    required this.selected,
    required this.label,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = FadenTokens.of(context);
    return Container(
      height: fadenMinTapTarget,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: tokens.flaeche, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          for (final value in values)
            Expanded(
              child: _Segment(
                text: label(value),
                selected: value == selected,
                tokens: tokens,
                onTap: onChanged == null ? null : () => onChanged!(value),
              ),
            ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  final String text;
  final bool selected;
  final FadenTokens tokens;
  final VoidCallback? onTap;

  const _Segment({required this.text, required this.selected, required this.tokens, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      enabled: onTap != null,
      label: text,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: selected ? tokens.faden : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  text,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: FadenTypeSizes.body,
                    color: selected ? tokens.grund : tokens.tinte,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Section heading in lists and sheets: 20 sp, no capitals.
class SectionTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;

  const SectionTitle(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    final tokens = FadenTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(text, style: TextStyle(color: tokens.tinte, fontSize: FadenTypeSizes.title)),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// A dialog button that is a Cupertino action on iOS (inside
/// `AlertDialog.adaptive`) and a text button elsewhere.
Widget adaptiveDialogAction(
  BuildContext context, {
  required String text,
  required VoidCallback onPressed,
  bool destructive = false,
}) {
  final platform = Theme.of(context).platform;
  if (platform == TargetPlatform.iOS || platform == TargetPlatform.macOS) {
    return CupertinoDialogAction(onPressed: onPressed, isDestructiveAction: destructive, child: Text(text));
  }
  return TextButton(
    onPressed: onPressed,
    style: destructive ? TextButton.styleFrom(foregroundColor: FadenTokens.of(context).fehler) : null,
    child: Text(text),
  );
}

/// "Download löschen?" -- true when confirmed.
Future<bool> confirmDeleteDownload(BuildContext context, String title) async {
  final ok = await showAdaptiveDialog<bool>(
    context: context,
    builder: (context) => AlertDialog.adaptive(
      title: Text(AppStrings.deleteConfirmTitle),
      content: Text(AppStrings.deleteConfirmBody(title)),
      actions: [
        adaptiveDialogAction(context, text: AppStrings.cancelAction, onPressed: () => Navigator.of(context).pop(false)),
        adaptiveDialogAction(
          context,
          text: AppStrings.deleteAction,
          destructive: true,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    ),
  );
  return ok ?? false;
}
