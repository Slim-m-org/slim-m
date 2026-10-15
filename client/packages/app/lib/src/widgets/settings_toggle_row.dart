// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one shape for "a setting you turn on or off".
///
/// There were three: `AppListRow(trailing: AppToggle(...))` in
/// `appearance_settings_section.dart`, and a hand-rolled
/// `Padding(Row(Expanded(Text), AppToggle))` in both `voice_settings_screen`
/// and `personal_status_sections`. The hand-rolled pair also reached for a
/// raw `TextStyle(color: tokens.textPrimary)` with no type step, so the label
/// tracked whatever `DefaultTextStyle` happened to be rather than a named one.
///
/// The wrapping label is why this is not simply "use [AppListRow] everywhere",
/// which was the obvious unification and would have lost text. [AppListRow] is
/// deliberately single-line and fixed-height so a rail of channels keeps an
/// even rhythm, and it ellipsizes its label to hold that. Three of these
/// settings carry a whole sentence - "Play a sound when someone joins or
/// leaves a call" - which fits on a desktop pane and does not fit beside a
/// toggle at phone width. Truncating the middle of a sentence describing what
/// a switch does is worse than a row of uneven height, so this one wraps.
///
/// **No row-wide `onTap`**, carried over from `_HighContrastRow`, which is the
/// version of this that was already right: [AppToggle] is its own tap target,
/// so a second one on the row fires both on a single tap, toggling the value
/// and immediately toggling it back.
///
/// Scope is a settings section. A toggle sitting in a *picker* list
/// (`role_assign_sheet`, `member_roles_sheet`) stays an [AppListRow] with a
/// trailing [AppToggle]: there the toggle is one column of a list item whose
/// label is a name and always short, which is a different thing from a
/// setting that has to describe itself.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class SettingsToggleRow extends StatelessWidget {
  const SettingsToggleRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    required this.semanticLabel,
    this.description,
    this.leading,
  });

  final String label;

  /// A second line qualifying the setting, for a switch whose effect is not
  /// obvious from its own name.
  final String? description;

  /// An icon in the same column an [AppListRow]'s leading uses, for a toggle
  /// that sits among such rows in one card.
  final Widget? leading;

  final bool value;
  final ValueChanged<bool>? onChanged;

  /// The toggle's own accessible name. Required rather than defaulted from
  /// [label]: the visible label is a sentence and the spoken one should be
  /// the setting, and silently reusing one as the other is how a screen
  /// reader ends up reading a paragraph per switch.
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: AppListRow.heightFor(context)),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s8,
          vertical: AppSpacing.s4,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          spacing: AppSpacing.s8,
          children: [
            if (leading != null) ExcludeSemantics(child: leading!),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: AppText.ui.copyWith(color: tokens.textPrimary),
                  ),
                  if (description != null) ...[
                    const SizedBox(height: AppSpacing.s4),
                    Text(
                      description!,
                      style: AppText.caption.copyWith(
                        color: tokens.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.s12),
            AppToggle(
              value: value,
              onChanged: onChanged,
              semanticLabel: semanticLabel,
            ),
          ],
        ),
      ),
    );
  }
}
