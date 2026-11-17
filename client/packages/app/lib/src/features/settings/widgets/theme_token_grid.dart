// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// All 19 theme colours as a two-column grid of tiles in their six groups, for
/// an editor with room for it. The picker opens across both columns under the
/// tile that was tapped.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/theme_links.dart';
import 'settings_section_header.dart';
import 'theme_colour_chip.dart';
import 'theme_colour_row.dart';

class ThemeTokenGrid extends StatelessWidget {
  const ThemeTokenGrid({
    super.key,
    required this.colours,
    required this.links,
    required this.failing,
    required this.openToken,
    required this.onTap,
    required this.picker,
  });

  final Map<String, Color> colours;
  final ThemeLinks links;

  /// The colours a failing check asks to change.
  final Set<String> failing;

  /// The tile whose picker is open here, or null.
  final String? openToken;
  final ValueChanged<String> onTap;

  /// The picker for [openToken], placed under its row of tiles.
  final Widget Function(String token) picker;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return SettingsSectionCard(
      key: const Key('theme-editor-all-colours'),
      title: 'All colours',
      description:
          'Linked colours follow their main colour until you change '
          'them.',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.s16,
            0,
            AppSpacing.s16,
            AppSpacing.s16,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final group in themeTokenGroups) ...[
                Padding(
                  padding: const EdgeInsets.only(
                    top: AppSpacing.s16,
                    bottom: AppSpacing.s8,
                  ),
                  child: Semantics(
                    header: true,
                    child: Text(
                      group.title.toUpperCase(),
                      semanticsLabel: group.title,
                      style: AppText.label.copyWith(
                        color: tokens.textSecondary,
                      ),
                    ),
                  ),
                ),
                ..._rows(group.tokens),
              ],
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _rows(List<String> group) => [
    for (var i = 0; i < group.length; i += 2) ...[
      if (i > 0) const SizedBox(height: AppSpacing.s8),
      Row(
        spacing: AppSpacing.s8,
        children: [
          for (final token in group.skip(i).take(2))
            Expanded(child: _tile(token)),
          if (i + 1 >= group.length) const Expanded(child: SizedBox()),
        ],
      ),
      if (group.skip(i).take(2).contains(openToken))
        _PickerFrame(child: picker(openToken!)),
    ],
  ];

  Widget _tile(String token) => _TokenTile(
    token: token,
    colour: colours[token]!,
    linked: links.isLinked(token),
    failing: failing.contains(token),
    open: token == openToken,
    onTap: () => onTap(token),
  );
}

class _PickerFrame extends StatelessWidget {
  const _PickerFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.s8),
      padding: const EdgeInsets.all(AppSpacing.s16),
      decoration: BoxDecoration(
        color: tokens.surfaceBase,
        border: Border.all(color: tokens.borderSubtle),
        borderRadius: BorderRadius.circular(AppRadii.card),
      ),
      child: child,
    );
  }
}

class _TokenTile extends StatelessWidget {
  const _TokenTile({
    required this.token,
    required this.colour,
    required this.linked,
    required this.failing,
    required this.open,
    required this.onTap,
  });

  final String token;
  final Color colour;
  final bool linked;
  final bool failing;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final radius = BorderRadius.circular(AppRadii.control);
    final label = themeTokenLabels[token]!;
    return Semantics(
      key: Key('theme-token-$token'),
      container: true,
      button: true,
      selected: open,
      onTap: onTap,
      label: [
        label,
        themeColourHex(token, colour),
        if (linked)
          'follows ${themeMainColourLabels[themeLinkParentOf(token)]}',
        if (failing) 'fails a contrast check',
      ].join(', '),
      excludeSemantics: true,
      child: AppInsetFocus(
        builder: (context, onFocusChange, focused) => Material(
          color: open ? tokens.surfaceSunken : tokens.surfaceBase,
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: BorderSide(
              color: open ? tokens.borderStrong : tokens.borderSubtle,
            ),
          ),
          child: InkWell(
            borderRadius: radius,
            focusColor: Colors.transparent,
            onFocusChange: onFocusChange,
            onTap: onTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: 52),
              foregroundDecoration: appInsetFocusDecoration(
                context,
                focused: focused,
                borderRadius: radius,
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.s12,
                vertical: AppSpacing.s8,
              ),
              child: Row(
                spacing: AppSpacing.s12,
                children: [
                  ThemeColourChip(colour: colour),
                  Expanded(child: _texts(tokens, label)),
                  if (linked)
                    Icon(
                      AppIcons.linkedColour,
                      size: AppSizes.icon12,
                      color: tokens.textSecondary,
                    ),
                  if (failing)
                    Icon(
                      AppIcons.warning,
                      size: AppSizes.icon16,
                      color: tokens.warnText,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _texts(AppTokens tokens, String label) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    spacing: 2,
    children: [
      Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppText.ui.copyWith(color: tokens.textPrimary),
      ),
      Text(
        themeColourHex(token, colour),
        maxLines: 1,
        style: AppText.caption.copyWith(
          fontFamily: AppFonts.mono,
          color: tokens.textSecondary,
        ),
      ),
    ],
  );
}
