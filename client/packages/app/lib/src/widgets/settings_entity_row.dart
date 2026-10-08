// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One administered thing in a settings list - a role, an invite, a custom
/// emoji, a removed member - and the notice a section shows when it has
/// nothing to put in front of you.
///
/// Both exist because five admin screens had independently hand-rolled the
/// same shape: an [AppCard] wrapping a `Row` of an optional leading widget, an
/// `Expanded` `Column` of a headline and one or two caption lines, a cluster
/// of trailing icon buttons, and an [AppErrorState] appended underneath when
/// the row's own action failed. Five copies of one idea is five chances for
/// one of them to drift, and they already had: the headline was an `AppText`
/// step in two of them and a bare `TextStyle` in the other three, and the
/// error banner sat inside the card in four and above it in the fifth.
///
/// Deliberately in `widgets/` rather than the design system, for the reason
/// [SettingsScreenScaffold]'s own library doc already gives about itself: this
/// is a composition of design-system primitives expressing *this app's*
/// settings conventions, not a primitive in its own right. A component library
/// has no business knowing that an administered entity carries an inline
/// failure banner.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// A multi-line row inside a [SettingsSectionCard]: what [AppListRow] would be
/// if it were not deliberately single-line and fixed-height.
///
/// [AppListRow] is the right primitive for a navigation row and the wrong one
/// here, and that is by its own design rather than an oversight: it clamps to
/// one line at [AppSizes.rowPointer]/[AppSizes.rowTouch] so a rail of channels
/// keeps an even rhythm. An invite carries a code, a badge, a uses-and-expiry
/// line and a role grant - four pieces over three lines - so it needs a row
/// that grows. The two are siblings rather than variants.
///
/// The row carries [AppListRow]'s hover tint whether or not it takes a tap of
/// its own: its actions do, and a pointer sweeping a list of these otherwise
/// reads the whole card as one inert slab. `surfaceSunken`, not
/// `surfaceRaised`, because these rows sit inside a card already painted
/// raised - the same choice [AppMenuItem] makes inside a floating menu.
class SettingsEntityRow extends StatefulWidget {
  const SettingsEntityRow({
    super.key,
    required this.headline,
    this.headlineStyle,
    this.badge,
    this.leading,
    this.details = const [],
    this.actions = const [],
    this.onTap,
    this.onTapSemanticLabel,
    this.error,
    this.onErrorRetry,
    this.onErrorDismiss,
    this.dense = false,
  });

  /// Halves the vertical padding, for a list long enough that row height is
  /// what makes it a scroll.
  final bool dense;

  /// Opens whatever the row is about, from anywhere on the row rather than
  /// from one small control at its right edge. A row whose only way in was a
  /// chevron gave a pointer a 30px target and a finger no hint that the rest
  /// of the row was inert.
  final VoidCallback? onTap;

  /// What activating the row does, for a screen reader. Defaults to the
  /// headline, which is what the row is about.
  final String? onTapSemanticLabel;

  /// The one thing this row is about: a role's name, an invite's code.
  final String headline;

  /// Overrides the headline's own text style, for the two rows whose headline
  /// is a code rather than a name and reads in the monospace face. The colour
  /// is still applied here, so a caller passes shape rather than a whole
  /// style and cannot accidentally drop the token.
  final TextStyle? headlineStyle;

  /// Sits immediately after the headline, on the same line: "Everyone",
  /// "Revoked", "Fully used".
  final Widget? badge;

  /// Before the headline: a custom emoji's own image, an avatar.
  final Widget? leading;

  /// Caption lines under the headline, in order. A row with nothing to add
  /// passes none rather than an empty string, so no blank line is reserved.
  final List<Widget> details;

  /// Trailing controls, usually [AppIconButton]s, rendered in a fixed-width
  /// cluster so every row in a list lands its buttons at the same x even when
  /// one row offers fewer of them.
  ///
  /// A null entry reserves an empty slot one [AppIconButton] wide rather than
  /// letting the remaining controls slide left. This row owns that layout
  /// itself - there used to be a second, publicly constructible widget for it
  /// that two call sites wrapped their own flat list in, producing a row
  /// nested one deep inside itself. Pass the flat list directly.
  final List<Widget?> actions;

  /// A failure from this row's own action, shown under it and staying until
  /// dealt with rather than vanishing on a timer - see `run_guarded.dart`.
  final String? error;
  final VoidCallback? onErrorRetry;
  final VoidCallback? onErrorDismiss;

  @override
  State<SettingsEntityRow> createState() => _SettingsEntityRowState();
}

class _SettingsEntityRowState extends State<SettingsEntityRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;

    final body = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: AppSpacing.s8,
        vertical: widget.dense ? AppSpacing.s4 : AppSpacing.s8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (widget.leading != null) ...[
                widget.leading!,
                const SizedBox(width: AppSpacing.s12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            widget.headline,
                            overflow: TextOverflow.ellipsis,
                            style: (widget.headlineStyle ?? AppText.body)
                                .copyWith(
                                  color: tokens.textPrimary,
                                  fontWeight: AppWeights.medium,
                                ),
                          ),
                        ),
                        if (widget.badge != null) ...[
                          const SizedBox(width: AppSpacing.s8),
                          widget.badge!,
                        ],
                      ],
                    ),
                    for (final detail in widget.details) ...[
                      const SizedBox(height: AppSpacing.s4),
                      detail,
                    ],
                  ],
                ),
              ),
              if (widget.actions.isNotEmpty)
                _SettingsEntityActions(children: widget.actions),
            ],
          ),
          if (widget.error != null) ...[
            const SizedBox(height: AppSpacing.s8),
            AppErrorState(
              message: widget.error!,
              onRetry: widget.onErrorRetry,
              onDismiss: widget.onErrorDismiss,
            ),
          ],
        ],
      ),
    );

    final onTap = widget.onTap;
    return MouseRegion(
      cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: AppMotion.reduced(context, AppMotion.fast),
        curve: AppMotion.entrance,
        decoration: BoxDecoration(
          color: _hovered ? tokens.surfaceSunken : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadii.control),
        ),
        child: onTap == null
            ? body
            : Semantics(
                button: true,
                label: widget.onTapSemanticLabel ?? widget.headline,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onTap,
                  child: body,
                ),
              ),
      ),
    );
  }
}

/// A caption line for [SettingsEntityRow.details], so a caller states what the
/// line says rather than restating the type step and colour token every time.
///
/// The five hand-rolled copies this replaces had all reached for
/// `AppText.caption.copyWith(color: tokens.textSecondary)` independently and
/// happened to agree; a shared widget is what makes that agreement structural.
class SettingsEntityDetail extends StatelessWidget {
  const SettingsEntityDetail(
    this.text, {
    super.key,
    this.tone,
    this.wrap = false,
  });

  final String text;

  /// Overrides the default `textSecondary`, for the one line that is not a
  /// neutral fact about the row (an invite's role grant, drawn in the accent).
  final Color? tone;

  /// Lets the line run onto as many lines as it needs instead of eliding.
  ///
  /// The default suits derived metadata - "3/10 uses, never expires", a
  /// handle, an upload date - which is short by construction and reads better
  /// clipped than wrapped, since it keeps a list of rows on an even rhythm.
  /// It is wrong for text a person wrote: a removal reason is the one thing a
  /// moderator opened the screen to read, and it shipped for one capture
  /// truncated to "Posted an invite link to another, unrelat..." before this
  /// existed. Pass true wherever the string came from a user rather than from
  /// a field this client formatted itself.
  final bool wrap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Text(
      text,
      overflow: wrap ? null : TextOverflow.ellipsis,
      style: AppText.caption.copyWith(color: tone ?? tokens.textSecondary),
    );
  }
}

/// The trailing action cluster [SettingsEntityRow] renders its own [actions]
/// through, reserving a slot for every position even where a given row
/// offers no control for it.
///
/// `roles_screen.dart` used to do this by hand, with a `SizedBox` of the
/// button's own width standing in for the delete and assign actions
/// `@everyone` does not get, and a comment explaining why. Without it the
/// remaining buttons slide right and no two rows in the list line up.
///
/// Private rather than exported: it used to be a second publicly
/// constructible widget, and two call sites wrapped their own flat action
/// list in one, producing one of these nested inside another - harmless
/// visually (Flutter tolerates a redundant `Row`), but two calling
/// conventions for the same parameter with nothing telling a caller which
/// theirs needed. `SettingsEntityRow.actions` is the only calling
/// convention now; this class is how it renders that list, not a second way
/// to build one.
///
/// The reserved slot is one [AppIconButton] wide, which is what makes the
/// alignment exact rather than approximate. A bare [Icon] or an [AppButton]
/// in the same cluster as a null still aligns nothing, because the stand-in
/// is sized for the button it stands in for and not for those. Every real
/// caller passes [AppIconButton]s; a caller needing a different control
/// beside a reserved slot should pass its own sized placeholder, not a null.
class _SettingsEntityActions extends StatelessWidget {
  const _SettingsEntityActions({required this.children});

  /// A null entry reserves an empty slot one [AppIconButton] wide.
  final List<Widget?> children;

  @override
  Widget build(BuildContext context) {
    final slot = AppTouchTargets.of(context)
        ? AppSizes.rowTouch
        : AppSizes.rowPointer;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final child in children)
          child ?? SizedBox(width: slot, height: slot),
      ],
    );
  }
}
