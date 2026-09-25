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
      decoration: BoxDecoration(color: tokens.flaeche, borderRadius: BorderRadius.circular(FadenRadii.tileLarge)),
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
            borderRadius: BorderRadius.circular(13),
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
/// the rows on one rounded card divided by hairlines, and an explanation
/// *below* ([footer]), as in the iPhone's own settings. Rows are usually
/// [ListTile]s; they draw their pressed state on the section's surface.
/// Since E75 the surface is a white [FadenTokens.karte] with a soft shadow
/// by day (the near-black card at night), radius 20.
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
            FadenCard(
              child: ListTileTheme.merge(
                contentPadding: const EdgeInsets.symmetric(horizontal: inset),
                // Secondary text on the card keeps 4.5:1 (E65, E75).
                subtitleTextStyle: TextStyle(
                  fontFamily: fadenFontFamily,
                  fontSize: FadenTypeSizes.caption,
                  color: tokens.leiseAufKarte,
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

/// A card of the softer look (decision E75): [FadenTokens.karte] with a
/// soft shadow by day instead of a hairline border, radius 20 unless
/// given. [color] and [border] override the fill and outline (the open
/// book's card, E73). A [Material], so list tiles and ink on it draw their
/// pressed state on the card.
class FadenCard extends StatelessWidget {
  final Widget child;
  final double radius;
  final Color? color;
  final BorderSide? border;

  const FadenCard({super.key, required this.child, this.radius = FadenRadii.card, this.color, this.border});

  @override
  Widget build(BuildContext context) {
    final tokens = FadenTokens.of(context);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: border ?? BorderSide.none,
    );
    return DecoratedBox(
      decoration: ShapeDecoration(shape: shape, shadows: tokens.kartenSchatten),
      child: Material(
        color: color ?? tokens.karte,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }
}

/// An icon (or icon and short text) on a subtle rounded-square tile
/// (decision E72), so the tap target is visible: [FadenTokens.karte] with
/// a small shadow by day, the near-black card at night (no glow). The
/// visible tile is [size] high (44 in bars, 56 in the player's controls);
/// the tap target is always at least [fadenMinTapTarget]. [tooltip] names
/// the button for VoiceOver unless the icon carries its own
/// `semanticLabel`.
class FadenTileButton extends StatelessWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;
  final double radius;

  /// Horizontal padding inside the tile once its content is wider than
  /// an icon (the sleep timer with its time left).
  final double padding;

  const FadenTileButton({
    super.key,
    required this.child,
    required this.onPressed,
    this.tooltip,
    this.size = 44,
    this.radius = FadenRadii.tile,
    this.padding = 0,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = FadenTokens.of(context);
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius));
    Widget button = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onPressed,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: fadenMinTapTarget, minHeight: fadenMinTapTarget),
        child: Center(
          widthFactor: 1,
          heightFactor: 1,
          child: Padding(
            padding: EdgeInsets.all(size >= fadenMinTapTarget ? 0 : (fadenMinTapTarget - size) / 2),
            child: DecoratedBox(
              decoration: ShapeDecoration(shape: shape, shadows: tokens.kachelSchatten),
              child: Material(
                color: tokens.karte,
                shape: shape,
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: onPressed,
                  customBorder: shape,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minWidth: size, minHeight: size, maxHeight: size),
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: padding),
                      child: Center(widthFactor: 1, child: child),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (tooltip != null) button = Tooltip(message: tooltip, child: button);
    return button;
  }
}

/// A small status capsule (decision E73): "noch 8 Std.", "neu", "gehört",
/// or "34 %" and "noch 8 Std." in one. [texts] are shown one after the
/// other with a thin dot between them, each its own [Text] (findable,
/// read one after the other).
class FadenCapsule extends StatelessWidget {
  final List<String> texts;
  final Color? background;
  final Color? foreground;

  const FadenCapsule({super.key, required this.texts, this.background, this.foreground});

  @override
  Widget build(BuildContext context) {
    final tokens = FadenTokens.of(context);
    final style = TextStyle(
      fontSize: FadenTypeSizes.caption,
      color: foreground ?? tokens.leiseAufKarte,
      height: 1.2,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background ?? tokens.flaecheAufKarte,
        borderRadius: BorderRadius.circular(100),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < texts.length; i++) ...[
              if (i > 0) Text(' · ', style: style),
              // Only the last part gives way when space is short.
              if (i < texts.length - 1)
                Text(texts[i], maxLines: 1, style: style)
              else
                Flexible(child: Text(texts[i], maxLines: 1, overflow: TextOverflow.ellipsis, style: style)),
            ],
          ],
        ),
      ),
    );
  }
}
