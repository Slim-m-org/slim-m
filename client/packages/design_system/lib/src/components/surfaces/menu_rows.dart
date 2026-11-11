// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rows an [AppMenu] holds besides a plain item: an on/off switch row, a
/// labelled segmented choice, the current value a submenu row shows, and the
/// inset that lines a control up with the row icons above and below it.
library;

import 'package:flutter/material.dart';

import '../../app_metrics.dart';
import '../../app_tokens.dart';
import '../../app_typography.dart';
import '../forms/segmented_control.dart';
import '../forms/toggle.dart';
import 'menu.dart';

/// The horizontal inset every menu row uses, so a control sits on the icons' left edge.
const double kMenuContentInset = 10;

/// [child] inset to the menu's content edges, for a control that is not a row.
class AppMenuControl extends StatelessWidget {
  const AppMenuControl({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: kMenuContentInset,
          vertical: AppSpacing.s4,
        ),
        child: child,
      );
}

/// The current choice, drawn secondary at the end of a submenu row.
class AppMenuValue extends StatelessWidget {
  const AppMenuValue(this.text, {super.key, this.maxWidth = 120});

  final String text;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppText.caption.copyWith(color: tokens.textSecondary),
      ),
    );
  }
}

/// An on/off setting: the label at the left edge, the switch at the right, the whole row a tap target.
class AppMenuSwitchRow extends StatelessWidget {
  const AppMenuSwitchRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => MergeSemantics(
        child: Semantics(
          toggled: value,
          child: AppMenuItem(
            label: label,
            onTap: () => onChanged(!value),
            trailing: ExcludeFocus(
              child: ExcludeSemantics(
                child: IgnorePointer(
                  child: AppToggle(value: value, onChanged: (_) {}),
                ),
              ),
            ),
          ),
        ),
      );
}

/// A one-of choice: a small [label] over a segmented control that spans the menu.
class AppMenuSegmentedRow extends StatelessWidget {
  const AppMenuSegmentedRow({
    super.key,
    required this.label,
    required this.options,
    required this.selectedIndex,
    required this.onSelected,
    this.note,
  });

  final String label;

  /// Fixed text at the end of the label line, such as what a default currently means.
  final String? note;
  final List<AppSegmentedOption> options;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: kMenuContentInset,
        vertical: AppSpacing.s4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: AppSpacing.s4,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: AppText.caption.copyWith(color: tokens.textSecondary),
                ),
              ),
              if (note != null) AppMenuValue(note!),
            ],
          ),
          AppSegmentedControl.fill(
            options: options,
            selectedIndex: selectedIndex,
            onSegmentSelected: onSelected,
            semanticLabel: label,
          ),
        ],
      ),
    );
  }
}
