// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A person's own switches for module badges and levels, narrowing what the Space allows.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../modules/providers/module_display_settings.dart';
import 'settings_section_header.dart';
import 'settings_toggle_row.dart';

const _spaceOff = 'Turned off for this Space.';

class ModuleDisplayCard extends ConsumerWidget {
  const ModuleDisplayCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final badgesAllowed = ref.watch(spaceMemberBadgesProvider);
    final sectionsAllowed = ref.watch(spaceProfileSectionsProvider);
    return SettingsSectionCard(
      title: 'Modules',
      children: [
        SettingsToggleRow(
          label: 'Show module badges',
          description: badgesAllowed
              ? 'Next to names in the member list.'
              : _spaceOff,
          value: ref.watch(personalMemberBadgesProvider),
          semanticLabel: 'Show module badges in the member list',
          onChanged: badgesAllowed
              ? (v) =>
                    ref.read(personalMemberBadgesProvider.notifier).setShown(v)
              : null,
        ),
        SettingsToggleRow(
          label: 'Show module levels',
          description: sectionsAllowed ? 'On profile cards.' : _spaceOff,
          value: ref.watch(personalProfileSectionsProvider),
          semanticLabel: 'Show module levels on profile cards',
          onChanged: sectionsAllowed
              ? (v) => ref
                    .read(personalProfileSectionsProvider.notifier)
                    .setShown(v)
              : null,
        ),
      ],
    );
  }
}
