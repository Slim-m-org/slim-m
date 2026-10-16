// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A settings row that states its current value and, to change it, drops a
/// dropdown down from the row on desktop or lifts a sheet on a phone.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'settings_section_header.dart';

/// One choice offered by a [SettingsSelectRow].
class SettingsChoice<T> {
  const SettingsChoice({required this.value, required this.label});

  final T value;
  final String label;
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
    this.sheetFootnote,
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

  /// A caveat line under the choices, shown where the reader is actually
  /// weighing them rather than as a section caption answering a question
  /// nobody asked yet.
  final String? sheetFootnote;

  /// Shown in place of a choice's label when [value] is null. Must never be a
  /// real choice's own label, or "not known" reads as that choice.
  final String unknownLabel;

  /// Renders as an indented sub-row of the row above, not a row of its own.
  final bool sub;

  String get _currentLabel {
    final current = value;
    if (current == null) return unknownLabel;
    return choices
        .firstWhere((c) => c.value == current, orElse: () => choices.first)
        .label;
  }

  /// Opens the choice sheet standalone, for a caller that wants this row's
  /// picker without its [AppListRow] presentation: [JoinPolicyRow] renders
  /// as a [ListTile] to match its neighbours but still needs this sheet.
  static Future<T?> pick<T>(
    BuildContext context, {
    required String title,
    required T? value,
    required List<SettingsChoice<T>> choices,
    String? footnote,
  }) {
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
                selected: choice.value == value,
                onTap: () => Navigator.of(sheetContext).pop(choice.value),
              ),
            if (footnote != null) AppMenuFootnote(footnote),
          ],
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    final chosen = await pick<T>(
      context,
      title: sheetTitle ?? label,
      value: value,
      choices: choices,
      footnote: sheetFootnote,
    );
    if (chosen != null && chosen != value) onChanged(chosen);
  }

  /// The desktop presentation: the choices drop down from the row, anchored to
  /// it, rather than a centred dialog taking focus for a choice this small. The
  /// sheet stays on a phone, where a value dropped over a 48dp row would be
  /// unmissable-adjacent and there is no pointer to dismiss it by clicking away.
  Future<void> _openDropdown(BuildContext context) async {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final anchor = context.findRenderObject()! as RenderBox;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final rect = Rect.fromPoints(
      anchor.localToGlobal(Offset.zero, ancestor: overlay),
      anchor.localToGlobal(
        anchor.size.bottomRight(Offset.zero),
        ancestor: overlay,
      ),
    );

    final chosen = await showMenu<T>(
      context: context,
      position: RelativeRect.fromRect(rect, Offset.zero & overlay.size),
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
              selected: choice.value == value,
            ),
          ),
        if (sheetFootnote != null)
          PopupMenuItem<T>(
            enabled: false,
            child: AppMenuFootnote(sheetFootnote!),
          ),
      ],
    );
    if (chosen != null && chosen != value) onChanged(chosen);
  }

  @override
  Widget build(BuildContext context) {
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
        onTap: () => desktop ? _openDropdown(context) : _open(context),
      );
    }
    return AppListRow(
      label: label,
      meta: _currentLabel,
      semanticLabel: '$label, currently $_currentLabel',
      // Down on desktop for a dropdown, right on a phone for a sheet.
      trailing: chevron,
      onTap: () => desktop ? _openDropdown(context) : _open(context),
    );
  }
}

/// One value in [SettingsSelectRow]'s desktop dropdown: a leading check on the
/// current choice, aligned so the labels line up whether ticked or not.
class _DropdownItem extends StatelessWidget {
  const _DropdownItem({required this.label, required this.selected});

  final String label;
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
