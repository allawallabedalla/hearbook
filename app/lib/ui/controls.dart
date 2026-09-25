import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../l10n/strings.dart';
import 'theme.dart';

/// A segmented choice in the token colours (decision E44): equal-width
/// segments, so a changed selection never moves or resizes anything (the
/// chips it replaces jumped in width with their check mark). Labels scale
/// down to fit rather than overflow at large text sizes. Height is the
/// 56 dp minimum tap target. The selected segment is filled in `faden` by
/// day and only outlined at night (decision E65: like the main button, no
/// lit amber surface in the dark). A choice ticks like an iOS picker.
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
                onTap: onChanged == null
                    ? null
                    : () {
                        unawaited(HapticFeedback.selectionClick());
                        onChanged!(value);
                      },
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
    // At night a ring, not a lit surface (E65).
    final outline = tokens.isDark;
    final Color textColor = !selected ? tokens.tinte : (outline ? tokens.faden : tokens.grund);
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
            color: selected && !outline ? tokens.faden : Colors.transparent,
            border: selected && outline ? Border.all(color: tokens.faden, width: 1.5) : null,
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
                    color: textColor,
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

/// An iOS-style grouped section (decision E65): an optional small header,
/// the rows on one rounded [FadenTokens.flaeche] surface divided by
/// hairlines, and an explanation *below* ([footer]), as in the iPhone's
/// own settings. Rows are usually [ListTile]s; they draw their pressed
/// state on the section's surface.
class FadenGroup extends StatelessWidget {
  final String? header;
  final Widget? headerTrailing;
  final List<Widget> rows;
  final Widget? footer;

  const FadenGroup({super.key, this.header, this.headerTrailing, required this.rows, this.footer});

  /// Side padding of rows inside a group.
  static const double inset = 16;

  @override
  Widget build(BuildContext context) {
    final tokens = FadenTokens.of(context);
    final quiet = TextStyle(color: tokens.tinteLeise, fontSize: FadenTypeSizes.caption, height: 1.3);
    final divided = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      if (i > 0) divided.add(Divider(height: 0.5, thickness: 0.5, indent: inset, color: tokens.linie));
      divided.add(rows[i]);
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (header != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(inset, 0, inset, 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Expanded(child: Semantics(header: true, child: Text(header!, style: quiet))),
                  if (headerTrailing != null) DefaultTextStyle.merge(style: quiet, child: headerTrailing!),
                ],
              ),
            ),
          if (divided.isNotEmpty)
            Material(
              color: tokens.flaeche,
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: ListTileTheme.merge(
                contentPadding: const EdgeInsets.symmetric(horizontal: inset),
                // Secondary text on the raised surface keeps 4.5:1 (E65).
                subtitleTextStyle: TextStyle(
                  fontFamily: fadenFontFamily,
                  fontSize: FadenTypeSizes.caption,
                  color: tokens.leiseAufFlaeche,
                  height: 1.25,
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: divided),
              ),
            ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(inset, 6, inset, 0),
              child: DefaultTextStyle.merge(style: quiet, child: footer!),
            ),
        ],
      ),
    );
  }
}

/// One choice in a list of choices, marked with a trailing check mark
/// like the iPhone's settings and the sleep-timer sheet (E61, E65) instead
/// of a radio button.
class FadenCheckRow extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const FadenCheckRow({super.key, required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = FadenTokens.of(context);
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: ListTile(
        minTileHeight: fadenMinTapTarget,
        title: Text(label),
        trailing: selected ? Icon(Icons.check, color: tokens.faden) : null,
        onTap: () {
          unawaited(HapticFeedback.selectionClick());
          onTap();
        },
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
