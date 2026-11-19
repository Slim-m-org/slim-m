// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The nav beside or in place of a settings pane, split out of `settings_panes.dart`.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/settings_index.dart';
import 'settings_hairline.dart';
import 'settings_pane.dart';
import 'settings_panes_chrome.dart';
import 'settings_rail_fade.dart';
import 'settings_search.dart';
import 'settings_section_header.dart';

/// The panes a settings screen offers, as the wide rail or the compact list.
class SettingsPanesNav extends StatelessWidget {
  const SettingsPanesNav({
    super.key,
    required this.groups,
    required this.rail,
    required this.selectedId,
    required this.showSelection,
    required this.onSelect,
    required this.searchEntries,
    required this.onSearchOpen,
    this.footer,
  });

  final List<SettingsPaneGroup> groups;
  final List<SettingsEntry> searchEntries;
  final ValueChanged<SettingsEntry> onSearchOpen;

  /// Inside the wide layout's nav column, which already pads and titles it.
  final bool rail;
  final String? selectedId;
  final bool showSelection;
  final void Function(String) onSelect;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final list = _list(context);
    return Column(
      children: [
        Expanded(
          child: searchEntries.isEmpty
              ? list
              : SettingsSearchArea(
                  entries: searchEntries,
                  paneLabels: {
                    for (final group in groups)
                      for (final pane in group.panes) pane.id: pane.label,
                  },
                  onOpen: onSearchOpen,
                  padding: rail
                      ? EdgeInsets.zero
                      : const EdgeInsets.symmetric(horizontal: AppSpacing.s16),
                  child: list,
                ),
        ),
        // A rule, so a row the list cuts off reads as scrolled under it rather than overlapped.
        if (footer != null && rail) ...[const SettingsHairline(), footer!],
      ],
    );
  }

  Widget _list(BuildContext context) =>
      rail ? _railList(context) : _compactList(context);

  Widget _railList(BuildContext context) {
    return SettingsRailFade(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          for (final (index, group) in groups.indexed) ...[
            if (group.label case final label?)
              GroupLabel(label, first: index == 0)
            else
              const SizedBox(height: AppSpacing.s20),
            for (final pane in group.panes) _row(context, pane),
          ],
        ],
      ),
    );
  }

  // Each group a raised card on the page, the same two tones the wide nav and its panes show.
  Widget _compactList(BuildContext context) {
    return ListView(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s16 + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        for (final (index, group) in groups.indexed)
          SettingsSectionCard(
            title: group.label,
            topGap: index == 0 ? AppSpacing.s8 : kSettingsSectionTopGap,
            children: [for (final pane in group.panes) _row(context, pane)],
          ),
        if (footer != null)
          SettingsSectionCard(
            topGap: kSettingsSectionTopGap,
            children: [footer!],
          ),
      ],
    );
  }

  Widget _row(BuildContext context, SettingsPane pane) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return AppListRow(
      label: pane.label,
      height: rail ? 32 : null,
      // Sized and colored to match the trailing chevron below, not Flutter's ~24px default.
      leading: pane.icon == null
          ? null
          : Icon(pane.icon, size: AppSizes.icon16, color: tokens.textSecondary),
      meta: pane.badge,
      selected: showSelection && pane.id == selectedId,
      // A chevron only where the row actually goes somewhere.
      trailing: showSelection
          ? null
          : Icon(
              AppIcons.chevronRight,
              size: AppSizes.icon16,
              color: tokens.textSecondary,
            ),
      onTap: () => onSelect(pane.id),
    );
  }
}
