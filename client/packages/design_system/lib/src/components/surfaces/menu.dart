// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A floating menu and its parts: a context menu, a dropdown, a command
/// palette result list, and the right-click/long-press sheet share this one
/// body.
///
/// [AppMenu] is one of exactly two places in this system allowed a shadow
/// ([AppShadows.menu]) rather than a hairline, because it is the one thing
/// here that is genuinely above the plane rather than part of it.
///
/// Its outer edge is [AppTokens.borderStrong], the case that token's own doc
/// names: "a menu against the surface it floats over". It was drawn in
/// `borderSubtle` until 2026-07-27, which left `borderStrong` referenced by no
/// widget at all and every edge in the app at the same weakest hairline. In
/// dark that edge went from 1.38:1 against the surface below it to 3.76:1, and
/// in true black from 1.62:1 to 4.48:1. A menu is unambiguously a UI component
/// rather than an incidental separator, so unlike the in-pane hairlines
/// discussed in `contrast_test.dart` it is not exempt from the 3:1 of WCAG
/// 1.4.11 - light did not reach it either, at 1.55:1, until 2026-08-25
/// darkened [AppTokens.borderStrong] to reach 3.11:1 against the same surface.
library;

import 'package:flutter/material.dart';

import '../../app_haptics.dart';
import '../../app_icons.dart';
import '../../app_metrics.dart';
import '../../app_motion.dart';
import '../../app_tokens.dart';
import '../../app_typography.dart';
import '../../touch_targets.dart';

/// A floating container for [AppMenuItem], [AppMenuLabel] and
/// [AppMenuDivider] children.
///
/// [floating] (default `true`, matching the source) toggles [AppShadows.menu];
/// a non-floating menu still gets the hairline border but sits flush rather
/// than lifted, for a menu embedded inline rather than popped over content.
class AppMenu extends StatelessWidget {
  const AppMenu(
      {super.key,
      required this.children,
      this.width = 250,
      this.floating = true,
      this.padding = const EdgeInsets.all(6)});

  final List<Widget> children;
  final double width;
  final bool floating;

  /// Zero for a card whose sections draw their own insets, like a profile.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;

    return Semantics(
      container: true,
      child: Container(
        width: width,
        decoration: BoxDecoration(
          color: tokens.surfaceRaised,
          border: Border.all(color: tokens.borderStrong),
          borderRadius: BorderRadius.circular(AppRadii.card),
          boxShadow: floating ? AppShadows.menu : null,
        ),
        // The default 6 is literal in the source, not on the --space-* grid.
        padding: padding,
        child: Material(
          type: MaterialType.transparency,
          child: Column(mainAxisSize: MainAxisSize.min, children: children),
        ),
      ),
    );
  }
}

/// The body for a [showAppSheet] call whose content is a list of
/// [AppMenuItem]s: [AppMenu]'s own card is right for a menu floating beside a
/// cursor and wrong inside a bottom sheet, which already draws its own
/// surface and drag handle - nesting [AppMenu] there doubles the chrome and
/// its fixed [width] leaves dead space either side on a phone.
///
/// On a compact layout this drops the card entirely and lets [children] span
/// the sheet's own full width; [AppMenuItem]'s `Row` already fills whatever
/// width it is given, so nothing here has to force it. On anything wider,
/// where [showAppSheet] presents a dialog instead, it renders the ordinary
/// floating [AppMenu] - pass `bare: true` to [showAppSheet] alongside this,
/// or the dialog's own panel nests around the card a second time.
class AppSheetMenu extends StatelessWidget {
  const AppSheetMenu({super.key, required this.children, this.width = 250});

  final List<Widget> children;

  /// [AppMenu]'s floating width once this renders as a dialog; unused on a
  /// compact layout, where the sheet decides the width instead.
  final double width;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.sizeOf(context).width >= kCompactWidth) {
      return AppMenu(width: width, children: children);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s8,
        0,
        AppSpacing.s8,
        AppSpacing.s8,
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

/// An uppercase micro section label inside an [AppMenu] ("Channel", "Danger
/// zone").
class AppMenuLabel extends StatelessWidget {
  const AppMenuLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;

    return Padding(
      // '8px 10px 6px' in the source: asymmetric top/bottom, literal rather
      // than on the --space-* grid.
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
      child: Text(
        text.toUpperCase(),
        style: AppText.label.copyWith(color: tokens.textSecondary),
      ),
    );
  }
}

/// A sentence-case caveat under a menu's choices - a readable line or two, not
/// the caps micro-label [AppMenuLabel] is. Kept a separate widget because a
/// whole explanation set in caps with tracking is a wall, not a footnote.
class AppMenuFootnote extends StatelessWidget {
  const AppMenuFootnote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      child: Text(
        text,
        style: AppText.caption.copyWith(color: tokens.textSecondary),
      ),
    );
  }
}

/// A hairline divider between groups of [AppMenuItem]s.
class AppMenuDivider extends StatelessWidget {
  const AppMenuDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;

    return Padding(
      // '5px 8px' in the source, literal rather than on the --space-* grid.
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 8),
      child: Container(height: 1, color: tokens.borderSubtle),
    );
  }
}

/// The tone an [AppMenuItem] renders in.
enum AppMenuItemTone { normal, danger }

/// One row inside an [AppMenu]: an optional leading icon, a label, and
/// optional trailing content (a shortcut hint, a chevron for [submenu]).
///
/// [touch] raises the row to [AppSizes.rowTouchMenu] (44, the touch minimum)
/// and widens the leading gap to
/// `space-12`; the pointer row is 34px, which matches [AppSizes.controlMd]
/// exactly. Left unset it follows [AppTouchTargets.of].
class AppMenuItem extends StatefulWidget {
  const AppMenuItem({
    super.key,
    required this.label,
    this.leading,
    this.trailing,
    this.submenu = false,
    this.selected = false,
    this.tone = AppMenuItemTone.normal,
    this.touch,
    this.onTap,
    this.semanticLabel,
  });

  final String label;
  final IconData? leading;
  final Widget? trailing;

  /// Adds a trailing chevron affordance for a row that opens a submenu.
  /// Combines with [trailing] rather than replacing it, matching the source's
  /// `{trailing}{submenu && <chevron>}`.
  final bool submenu;

  /// The current-value background (`accentSoft`). Also draws a trailing check
  /// unless a [trailing] widget takes that slot, so the choice never rests on
  /// a tint.
  final bool selected;
  final AppMenuItemTone tone;

  /// Null means "whatever this subtree is at", read from [AppTouchTargets].
  final bool? touch;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  State<AppMenuItem> createState() => _AppMenuItemState();
}

class _AppMenuItemState extends State<AppMenuItem> {
  bool _hovered = false;
  bool _focused = false;

  /// A finger has no hover, so on a phone this is the only sign a tap landed
  /// before its action runs - [AppListRow]'s own reasoning, applied here.
  bool _pressed = false;

  Color _toneColor(AppTokens tokens) => switch (widget.tone) {
        AppMenuItemTone.normal => tokens.textPrimary,
        AppMenuItemTone.danger => tokens.dangerText,
      };

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final active = widget.onTap != null;

    return Semantics(
      label: widget.semanticLabel ?? widget.label,
      button: true,
      selected: widget.selected,
      enabled: active,
      child: FocusableActionDetector(
        enabled: active,
        mouseCursor: active ? SystemMouseCursors.click : MouseCursor.defer,
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: !active
            ? const <Type, Action<Intent>>{}
            : <Type, Action<Intent>>{
                ActivateIntent: CallbackAction<ActivateIntent>(
                  onInvoke: (_) => widget.onTap!(),
                ),
              },
        child: GestureDetector(
          onTapDown: active ? (_) => setState(() => _pressed = true) : null,
          onTapUp: active ? (_) => setState(() => _pressed = false) : null,
          onTapCancel: active ? () => setState(() => _pressed = false) : null,
          onTap: active
              ? () {
                  AppHaptics.selection();
                  widget.onTap!();
                }
              : null,
          child: _content(tokens, active),
        ),
      ),
    );
  }

  Color _fill(AppTokens tokens) {
    if (widget.selected) return tokens.accentSoft;
    return _hovered || _pressed ? tokens.surfaceSunken : Colors.transparent;
  }

  Widget? _trailingIcon(AppTokens tokens) {
    if (widget.trailing != null) return widget.trailing;
    if (!widget.selected) return null;
    return Icon(AppIcons.check, size: AppSizes.icon16, color: tokens.accent);
  }

  Widget _content(AppTokens tokens, bool active) {
    final touch = widget.touch ?? AppTouchTargets.of(context);
    // An item with no action is dimmed throughout, so it cannot pass for one that works.
    final ink = active ? _toneColor(tokens) : tokens.textDisabled;
    // The source dims the icon to text-secondary for the normal tone even
    // though the label is text-primary; danger keeps icon and label in step.
    final iconInk = active && widget.tone == AppMenuItemTone.normal
        ? tokens.textSecondary
        : ink;
    final trailing = _trailingIcon(tokens);

    // The tint rides AppListRow's fast hover clock; density is still layout.
    return AnimatedContainer(
      duration: AppMotion.reduced(context, AppMotion.fast),
      curve: AppMotion.entrance,
      height: touch ? AppSizes.rowTouchMenu : AppSizes.controlMd,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: _fill(tokens),
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      foregroundDecoration: _focused
          ? BoxDecoration(
              border: Border.all(color: tokens.focusRing, width: 2),
              borderRadius: BorderRadius.circular(AppRadii.control),
            )
          : null,
      child: Row(
        spacing: touch ? AppSpacing.s12 : AppSpacing.s8,
        children: [
          if (widget.leading != null)
            Icon(widget.leading, size: AppSizes.icon16, color: iconInk),
          Expanded(
            // Excluded because the Semantics wrapper above already names this
            // item; merging the two doubles the announcement.
            child: ExcludeSemantics(
              child: Text(
                widget.label,
                overflow: TextOverflow.ellipsis,
                style: (touch ? AppText.body : AppText.ui).copyWith(color: ink),
              ),
            ),
          ),
          if (trailing != null || widget.submenu)
            Row(
              mainAxisSize: MainAxisSize.min,
              // 6 is literal in the source, not on the --space-* grid.
              spacing: 6,
              children: [
                if (trailing != null) trailing,
                if (widget.submenu)
                  Icon(AppIcons.chevronRight,
                      size: 12, color: tokens.textSecondary),
              ],
            ),
        ],
      ),
    );
  }
}
