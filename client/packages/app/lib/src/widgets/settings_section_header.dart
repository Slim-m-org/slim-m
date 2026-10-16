// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The container vocabulary every settings and administration screen is built
/// from: a group header naming who a run of sections belongs to, the section
/// header each one opens with, and [SettingsSectionCard], which is *the* way
/// this app expresses "a group of related settings".
///
/// See [docs/decisions/0013-settings-container-system.md] for the survey that
/// made this the single idiom and the six competing ones it replaced. The
/// short version: a screen in this area is a stack of [SettingsSectionCard]s
/// and nothing else is a container, so a reader crossing from personal
/// settings to a moderation screen meets one rhythm rather than six.
///
/// **Horizontal inset is owned by the screen frame, never by a section.**
/// [SettingsScreenScaffold] and [SettingsPanesScaffold]'s own pane body each
/// pad by [AppSpacing.s16] already, and this file used to add another
/// [AppSpacing.s16] on top - so personal and Space settings sat at 32 while
/// every admin screen sat at 16 and the debug log sat at 0. Three insets on
/// sibling screens is exactly the incoherence this vocabulary exists to
/// close, and one owner for the inset is what keeps it closed.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// `SettingsGroupHeader` used to live here, a step up the type scale from
/// [SettingsSectionHeader], for naming a run of sections rather than one.
/// Its last caller was `AppInfoSection`, which used it *instead of* a
/// container rather than above several - the one personal-settings section
/// with no bordered box at all. That section is a [SettingsSectionCard] now
/// like every other, which left this with no callers, so it is deleted rather
/// than kept as a second header level nothing reaches. A future screen that
/// genuinely needs to name a run of sections should bring it back
/// deliberately rather than inherit it as dead code.
class SettingsSectionHeader extends StatelessWidget {
  const SettingsSectionHeader(
    this.title, {
    super.key,
    this.description,
    this.flush = false,
  });

  final String title;
  final String? description;

  /// The redesigned settings spacing (28 above, 10 to the card, 2 between
  /// title and description), beside a [SettingsSectionCard.flush] card.
  final bool flush;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: EdgeInsets.only(
        top: flush ? 28 : AppSpacing.s24,
        bottom: flush ? 10 : AppSpacing.s8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              title,
              style: AppText.ui.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.semi,
              ),
            ),
          ),
          if (description != null) ...[
            SizedBox(height: flush ? 2 : AppSpacing.s4),
            Text(
              description!,
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ],
        ],
      ),
    );
  }
}

/// A [SettingsSectionHeader] above an [AppCard] holding its rows, so a
/// section reads as a bordered group rather than rows floating loose on the
/// plain pane background - the flat, undifferentiated look the owner
/// reported on a wide desktop window.
///
/// The header stays outside the card and keeps its own prominent styling
/// (unlike [AppCard.title], which is a small uppercase micro-label meant for
/// a nested panel): a settings section's name is the more important of the
/// two things on screen, and this widget exists only to give what follows it
/// a visible boundary, not to replace it.
///
/// The rows sit inside a [Material] of their own: a [ListTile] (several
/// sections still use one) paints its background and ink splashes on the
/// nearest [Material], and [AppCard]'s own filled, bordered box would
/// otherwise sit between it and the Scaffold's, which is exactly the
/// "background color or ink splashes may be invisible" assertion a tap on
/// one of those rows used to raise.
class SettingsSectionCard extends StatelessWidget {
  const SettingsSectionCard({
    super.key,
    this.title,
    required this.children,
    this.description,
    this.crossAxisAlignment = CrossAxisAlignment.start,
    this.divided = false,
    this.flush = false,
    this.trailing,
  });

  /// Rows edge to edge with a hairline between every child and no inner
  /// padding: the personal settings redesign. Non-row content goes in a
  /// [SettingsCardBlock] so it keeps its own 16px inset.
  final bool flush;

  /// Beside the title, for a section-level action (a refresh button).
  final Widget? trailing;

  /// Draws a hairline between children, for a card that is a list of rows.
  ///
  /// Off by default: a card holding free-form content (a picker, an error
  /// box) has no row boundaries for a rule to mark.
  final bool divided;

  /// Null for a screen whose entire body is this one group, where a header
  /// would only restate the app bar title above it.
  ///
  /// The header exists to tell several groups apart, so on a screen with one
  /// group it is a hairline and 24dp of space carrying no information -
  /// "Roles" under a screen titled "Roles". Applying "a screen body is a
  /// stack of section cards" literally produced exactly that on four screens
  /// before this was nullable, which is worth recording: a vocabulary rule
  /// still needs the judgement about when a slot has nothing to say.
  ///
  /// A single-group screen that *can* say something useful should still pass
  /// a title, or a [description]: "Invites" beside a "New invite" form earns
  /// its header because there are two groups to separate.
  final String? title;
  final String? description;

  final List<Widget> children;

  /// The card's own inner column, not `stretch`: a row widget (`AppListRow`,
  /// `ListTile`, `SettingsSelectRow`) already fills whatever width it is
  /// offered on its own, but non-row content (`MediaCapabilitySection`'s
  /// button, `AvatarSettingsSection`'s centred picture) needs to keep
  /// whichever alignment it had before this widget existed rather than being
  /// stretched into a shape nothing here ever asked for.
  final CrossAxisAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) {
    // A description with no title had nowhere to render and no test caught it; this catches it instead.
    assert(
      title != null || description == null,
      'SettingsSectionCard.description needs a title to render under',
    );
    final tokens = Theme.of(context).extension<AppTokens>()!;
    if (flush) return _flush(tokens);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null)
          SettingsSectionHeader(title!, description: description)
        else
          const SizedBox(height: AppSpacing.s24),
        AppCard(
          padding: const EdgeInsets.all(AppSpacing.s8),
          child: Material(
            type: MaterialType.transparency,
            child: AppStrongLabelScope(
              child: Column(
                crossAxisAlignment: crossAxisAlignment,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < children.length; i++) ...[
                    if (divided && i > 0)
                      Divider(
                        height: 1,
                        thickness: 1,
                        indent: AppSpacing.s8,
                        endIndent: AppSpacing.s8,
                        color: tokens.borderSubtle,
                      ),
                    children[i],
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _flush(AppTokens tokens) {
    final header = title == null
        ? const SizedBox(height: 28)
        : SettingsSectionHeader(title!, description: description, flush: true);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (trailing == null)
          header
        else
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(child: header),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: trailing,
              ),
            ],
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: tokens.surfaceRaised,
            border: Border.all(color: tokens.borderSubtle),
            borderRadius: BorderRadius.circular(AppRadii.card),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.card - 1),
            child: Material(
              type: MaterialType.transparency,
              child: AppStrongLabelScope(
                child: AppCardRowScope(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < children.length; i++) ...[
                        if (i > 0)
                          Divider(
                            height: 1,
                            thickness: 1,
                            color: tokens.borderSubtle,
                          ),
                        children[i],
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Non-row content inside a [SettingsSectionCard.flush] card (form fields, a
/// preview), inset by the card's own 16 on every side.
class SettingsCardBlock extends StatelessWidget {
  const SettingsCardBlock({
    super.key,
    required this.children,
    this.gap = AppSpacing.s16,
  });

  final List<Widget> children;
  final double gap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(AppSpacing.s16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: gap,
      children: children,
    ),
  );
}

/// A setting that belongs to the row above it (the key under push to talk,
/// the days under a schedule): indented, shorter, on a slightly deeper tint.
class SettingsSubRow extends StatelessWidget {
  const SettingsSubRow({
    super.key,
    required this.label,
    this.leading,
    this.trailing,
    this.onTap,
    this.semanticLabel,
  });

  final String label;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final row = Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.fromLTRB(32, 6, AppSpacing.s16, 6),
      color: Color.lerp(tokens.surfaceBase, tokens.surfaceRaised, 0.5),
      child: Row(
        spacing: 10,
        children: [
          if (leading != null) leading!,
          Expanded(
            child: Text(
              label,
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
    if (onTap == null) return row;
    return Semantics(
      button: true,
      label: semanticLabel ?? label,
      child: InkWell(
        onTap: onTap,
        child: ExcludeSemantics(child: row),
      ),
    );
  }
}

/// The padding and least height a settings row takes: edge to edge inside a
/// flush card, inset inside a padded one.
class SettingsRowMetrics {
  const SettingsRowMetrics._(this.minHeight, this.inset, this.vertical);

  factory SettingsRowMetrics.of(BuildContext context) =>
      AppCardRowScope.of(context)
      ? const SettingsRowMetrics._(
          AppCardRowScope.minHeight,
          AppCardRowScope.inset,
          AppSpacing.s8,
        )
      : SettingsRowMetrics._(
          AppListRow.heightFor(context),
          AppSpacing.s8,
          AppSpacing.s4,
        );

  final double minHeight;
  final double inset;
  final double vertical;
}
