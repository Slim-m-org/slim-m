// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// All 19 theme colours on a narrow editor: six collapsible groups, each
/// showing its colours as a strip of chips until it opens into full-width
/// rows, with every opacity slider directly under its colour.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/theme_draft.dart';
import '../providers/theme_links.dart';
import 'settings_section_header.dart';
import 'theme_colour_chip.dart';
import 'theme_colour_row.dart';
import 'theme_opacity_slider.dart';

class ThemeTokenGroupsCompact extends StatefulWidget {
  const ThemeTokenGroupsCompact({
    super.key,
    required this.draft,
    required this.onTap,
  });

  final ThemeDraft draft;

  /// Opens the picker for a colour.
  final ValueChanged<String> onTap;

  @override
  State<ThemeTokenGroupsCompact> createState() =>
      _ThemeTokenGroupsCompactState();
}

class _ThemeTokenGroupsCompactState extends State<ThemeTokenGroupsCompact> {
  final _open = <String>{};

  void _toggle(String title) => setState(
    () => _open.contains(title) ? _open.remove(title) : _open.add(title),
  );

  @override
  Widget build(BuildContext context) {
    final draft = widget.draft;
    final colours = draft.document.colours;
    final failing = draft.failingColours;
    return SettingsSectionCard(
      key: const Key('theme-editor-all-colours'),
      title: 'All colours',
      description:
          'Linked colours follow their main colour until you change '
          'them.',
      children: [
        for (final group in themeTokenGroups) ...[
          _GroupHeader(
            group: group,
            colours: colours,
            open: _open.contains(group.title),
            failing: group.tokens.any(failing.contains),
            onTap: () => _toggle(group.title),
          ),
          if (_open.contains(group.title))
            for (final token in group.tokens)
              _ColourWithOpacity(
                draft: draft,
                token: token,
                failing: failing.contains(token),
                onTap: () => widget.onTap(token),
              ),
        ],
      ],
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.group,
    required this.colours,
    required this.open,
    required this.failing,
    required this.onTap,
  });

  final ThemeTokenGroup group;
  final Map<String, Color> colours;
  final bool open;
  final bool failing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return AppListRow(
      key: Key('theme-group-${group.title}'),
      label: group.title,
      semanticLabel: [
        group.title,
        if (failing) 'a colour fails a contrast check',
        open ? 'expanded' : 'collapsed',
      ].join(', '),
      leading: Icon(
        open ? AppIcons.chevronDown : AppIcons.chevronRight,
        size: AppSizes.icon16,
        color: tokens.textSecondary,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: AppSpacing.s8,
        children: [
          if (failing)
            Icon(
              AppIcons.warning,
              size: AppSizes.icon16,
              color: tokens.warnText,
            ),
          _ChipStrip(colours: [for (final t in group.tokens) colours[t]!]),
        ],
      ),
      onTap: onTap,
    );
  }
}

/// A group's colours as overlapping chips, so a folded group still shows them.
class _ChipStrip extends StatelessWidget {
  const _ChipStrip({required this.colours});

  final List<Color> colours;

  static const _chip = AppSizes.icon16;
  static const _step = _chip - AppSpacing.s4;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: _step * (colours.length - 1) + _chip,
    height: _chip,
    child: Stack(
      children: [
        for (final (i, colour) in colours.indexed)
          Positioned(
            left: _step * i,
            child: ThemeColourChip(colour: colour, size: _chip),
          ),
      ],
    ),
  );
}

/// A colour's row and, for a see-through one, its opacity right under it.
class _ColourWithOpacity extends StatelessWidget {
  const _ColourWithOpacity({
    required this.draft,
    required this.token,
    required this.failing,
    required this.onTap,
  });

  final ThemeDraft draft;
  final String token;
  final bool failing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colour = draft.document.colours[token]!;
    final linked = draft.links.isLinked(token);
    final parent = themeLinkParentOf(token);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ThemeColourRow(
          key: Key('theme-token-$token'),
          token: token,
          colour: colour,
          label: themeTokenLabels[token]!,
          description: linked
              ? 'Follows ${themeMainColourLabels[parent]}'
              : null,
          linked: linked,
          failing: failing,
          onTap: onTap,
        ),
        if (themeAlphaTokens.contains(token))
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppCardRowScope.inset + AppSizes.icon24 + AppSpacing.s8,
              0,
              AppCardRowScope.inset,
              AppSpacing.s8,
            ),
            child: ThemeOpacitySlider(
              sliderKey: Key('theme-opacity-$token'),
              token: token,
              value: colour.a,
              onChanged: (v) => draft.setOpacity(token, v),
            ),
          ),
      ],
    );
  }
}
