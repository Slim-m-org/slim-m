// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The three colours most themes need, Background, Accent and Text, each
/// saying which colours follow it. On a wide editor the picker opens under
/// the row that was tapped.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/theme_links.dart';
import 'settings_section_header.dart';
import 'theme_colour_row.dart';

/// The main colours in the order the card lists them.
const themeMainColours = ['surfaceBase', 'accent', 'textPrimary'];

/// How each follower is named in its main colour's description.
const _followerNames = {
  'surfaceSunken': 'sunken',
  'surfaceRaised': 'raised',
  'accentFill': 'fill',
  'accentRing': 'ring',
  'focusRing': 'focus',
  'textSecondary': 'secondary',
  'textDisabled': 'disabled',
};

/// "Sunken and raised follow it.", or null once nothing follows [parent].
String? themeFollowersSentence(ThemeLinks links, String parent) {
  final names = [for (final f in links.followers(parent)) _followerNames[f]!];
  if (names.isEmpty) return null;
  final listed = names.length == 1
      ? names.single
      : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
  final verb = names.length == 1 ? 'follows' : 'follow';
  return '${listed[0].toUpperCase()}${listed.substring(1)} $verb it.';
}

class ThemeMainColours extends StatelessWidget {
  const ThemeMainColours({
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
  final Set<String> failing;

  /// The row whose picker is open here, or null.
  final String? openToken;
  final ValueChanged<String> onTap;
  final Widget Function(String token) picker;

  @override
  Widget build(BuildContext context) => SettingsSectionCard(
    key: const Key('theme-editor-main-colours'),
    title: 'Main colours',
    description: 'Change these three and the rest follow.',
    children: [
      for (final token in themeMainColours)
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ThemeColourRow(
              key: Key('theme-main-$token'),
              token: token,
              colour: colours[token]!,
              label: themeMainColourLabels[token]!,
              description: themeFollowersSentence(links, token),
              failing: failing.contains(token),
              open: token == openToken,
              onTap: () => onTap(token),
            ),
            if (token == openToken)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.s16,
                  AppSpacing.s12,
                  AppSpacing.s16,
                  AppSpacing.s16,
                ),
                child: picker(token),
              ),
          ],
        ),
    ],
  );
}
