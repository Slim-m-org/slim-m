// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A settings row that states its current value and, to change it, drops a
/// dropdown down from the row on desktop or lifts a sheet on a phone.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'settings_choice_picker.dart';
import 'settings_section_header.dart';
import 'settings_search.dart';

/// One choice offered by a [SettingsSelectRow].
class SettingsChoice<T> {
  const SettingsChoice({
    required this.value,
    required this.label,
    this.leading,
    this.disabledReason,
  });

  final T value;
  final String label;

  /// A small mark shown before the label and beside the current value.
  final Widget? leading;

  /// Shows the choice but not choosable, with this said on hover.
  final String? disabledReason;
}

/// Replaces a row of segmented cards for settings with more than about three
/// options. Four cards on a phone wrap their labels mid-word, and the value a
/// setting currently holds is what a reader is looking for anyway.
class SettingsSelectRow<T> extends StatelessWidget {
  const SettingsSelectRow({
    super.key,
    required this.label,
    required this.value,
    required this.choices,
    required this.onChanged,
    this.sheetTitle,
    this.description,
    this.unknownLabel = 'Unknown',
    this.sub = false,
  });

  final String label;

  /// Null means "no choice known yet", not any of [choices]: a caller with
  /// nothing to read the current value back from must be able to say so
  /// rather than being forced to assert one of the real choices in its place.
  final T? value;
  final List<SettingsChoice<T>> choices;
  final ValueChanged<T> onChanged;

  /// Defaults to [label]; set it where the row's label is too terse to head a
  /// sheet on its own.
  final String? sheetTitle;

  /// A line under the label saying what the setting governs. It never goes
  /// inside the open dropdown or sheet.
  final String? description;

  /// Shown in place of a choice's label when [value] is null. Must never be a
  /// real choice's own label, or "not known" reads as that choice.
  final String unknownLabel;

  /// Renders as an indented sub-row of the row above, not a row of its own.
  final bool sub;

  SettingsChoice<T>? get _currentChoice {
    final current = value;
    if (current == null) return null;
    return choices.firstWhere(
      (c) => c.value == current,
      orElse: () => choices.first,
    );
  }

  String get _currentLabel => _currentChoice?.label ?? unknownLabel;

  /// Opens the picker standalone, for a caller that wants this row's picker
  /// without its [AppListRow] presentation: [JoinPolicyRow] renders as a
  /// [ListTile] to match its neighbours. On desktop the choices drop down
  /// anchored to [context]'s box, and a phone gets a sheet, where there is no
  /// pointer to dismiss a dropdown by clicking away.
  static Future<T?> pick<T>(
    BuildContext context, {
    required String title,
    required T? value,
    required List<SettingsChoice<T>> choices,
  }) {
    if (MediaQuery.sizeOf(context).width >= kCompactWidth) {
      return _pickDropdown<T>(context, value: value, choices: choices);
    }
    if (choicesNeedSearch(choices.length)) {
      return showSearchableChoiceSheet<T>(
        context,
        title: title,
        value: value,
        choices: choices,
      );
    }
    return showAppSheet<T>(
      context,
      bare: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: AppSheetMenu(
          children: [
            AppMenuLabel(title),
            for (final choice in choices)
              AppMenuItem(
                label: choice.label,
                leadingWidget: choice.leading,
                selected: choice.value == value,
                onTap: () => Navigator.of(sheetContext).pop(choice.value),
              ),
          ],
        ),
      ),
    );
  }

  static Future<T?> _pickDropdown<T>(
    BuildContext context, {
    required T? value,
    required List<SettingsChoice<T>> choices,
  }) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final anchor = context.findRenderObject()! as RenderBox;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final bottomRight = anchor.localToGlobal(
      anchor.size.bottomRight(Offset.zero),
      ancestor: overlay,
    );
    // A zero-width rect makes the menu right-align to the value side, below the row.
    final point = Rect.fromLTWH(bottomRight.dx, bottomRight.dy + 4, 0, 0);
    final position = RelativeRect.fromRect(point, Offset.zero & overlay.size);
    if (choicesNeedSearch(choices.length)) {
      return showSearchableChoiceMenu<T>(
        context,
        position: position,
        value: value,
        choices: choices,
      );
    }
    return showMenu<T>(
      context: context,
      position: position,
      color: tokens.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.card),
        side: BorderSide(color: tokens.borderStrong),
      ),
      constraints: const BoxConstraints(minWidth: 200, maxWidth: 300),
      items: [
        for (final choice in choices)
          PopupMenuItem<T>(
            value: choice.value,
            child: _DropdownItem(
              label: choice.label,
              leading: choice.leading,
              selected: choice.value == value,
            ),
          ),
      ],
    );
  }

  Future<void> _open(BuildContext context) async {
    final chosen = await pick<T>(
      context,
      title: sheetTitle ?? label,
      value: value,
      choices: choices,
    );
    if (chosen != null && chosen != value) onChanged(chosen);
  }

  @override
  Widget build(BuildContext context) =>
      SettingsHighlightTarget(label: label, child: _content(context));

  /// The most of the row a long value may take, so the label keeps its place.
  static const _valueShare = 0.55;

  Widget _content(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final desktop = MediaQuery.sizeOf(context).width >= kCompactWidth;
    final chevron = Icon(
      desktop ? AppIcons.chevronDown : AppIcons.chevronRight,
      size: AppSizes.icon16,
      color: tokens.textSecondary,
    );
    if (sub) {
      return SettingsSubRow(
        label: label,
        semanticLabel: '$label, currently $_currentLabel',
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: AppSpacing.s8,
          children: [
            if (_currentChoice?.leading != null) _currentChoice!.leading!,
            Flexible(
              child: Text(
                _currentLabel,
                overflow: TextOverflow.ellipsis,
                style: AppText.ui.copyWith(color: tokens.textPrimary),
              ),
            ),
            chevron,
          ],
        ),
        onTap: () => _open(context),
      );
    }
    // AppListRow gives a trailing no bound, so the value is capped at the row's own width, not the window's.
    return LayoutBuilder(
      builder: (context, box) => _valueRow(context, chevron, box.maxWidth),
    );
  }

  Widget _valueRow(BuildContext context, Widget chevron, double rowWidth) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return AppListRow(
      label: label,
      subtitle: description,
      semanticLabel: '$label, currently $_currentLabel',
      trailing: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: rowWidth * _valueShare),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 6,
          children: [
            if (_currentChoice?.leading != null) _currentChoice!.leading!,
            Flexible(
              child: Text(
                _currentLabel,
                overflow: TextOverflow.ellipsis,
                style: AppText.ui.copyWith(color: tokens.textPrimary),
              ),
            ),
            // Down on desktop for a dropdown, right on a phone for a sheet.
            chevron,
          ],
        ),
      ),
      onTap: () => _open(context),
    );
  }
}

/// One value in [SettingsSelectRow]'s desktop dropdown: a leading check on the
/// current choice, aligned so the labels line up whether ticked or not.
class _DropdownItem extends StatelessWidget {
  const _DropdownItem({
    required this.label,
    required this.selected,
    this.leading,
  });

  final String label;
  final Widget? leading;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Row(
      children: [
        SizedBox(
          width: AppSizes.icon16 + AppSpacing.s8,
          child: selected
              ? Icon(
                  AppIcons.check,
                  size: AppSizes.icon16,
                  color: tokens.textPrimary,
                )
              : null,
        ),
        if (leading != null) ...[
          leading!,
          const SizedBox(width: AppSpacing.s8),
        ],
        Expanded(
          child: Text(
            label,
            style: AppText.body.copyWith(color: tokens.textPrimary),
          ),
        ),
      ],
    );
  }
}
