// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A person's own switch for where module output shows, narrowing what the Space allows.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../modules/providers/module_display_settings.dart';
import 'settings_toggle_row.dart';

/// Labelled like the Space-wide switch it narrows, in Space settings > Modules.
enum ModuleDisplayKind {
  memberBadges('Badges in member list'),
  profileSections('Sections on profiles');

  const ModuleDisplayKind(this.label);

  final String label;
}

class PersonalModuleToggle extends ConsumerWidget {
  const PersonalModuleToggle(this.display, {super.key});

  final ModuleDisplayKind display;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final badges = display == ModuleDisplayKind.memberBadges;
    final allowed = ref.watch(
      badges ? spaceMemberBadgesProvider : spaceProfileSectionsProvider,
    );
    final personal = badges
        ? personalMemberBadgesProvider
        : personalProfileSectionsProvider;
    return SettingsToggleRow(
      label: display.label,
      description: allowed ? null : 'Turned off for this Space.',
      value: ref.watch(personal),
      semanticLabel: display.label,
      onChanged: allowed
          ? (v) => ref.read(personal.notifier).setShown(v)
          : null,
    );
  }
}
