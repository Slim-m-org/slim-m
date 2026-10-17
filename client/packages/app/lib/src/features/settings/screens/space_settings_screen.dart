// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Space settings: reports, invites, roles, channel permissions, who can
/// join, and emoji, in the same nav-and-pane shape personal settings has
/// ([SettingsPanesScaffold]) rather than a scroll of rows that each push a
/// separate route. Reached only from the rail's Space menu, which hides
/// itself for a caller holding none of the gating bits.
///
/// A caller holding none of them gets a stated reason rather than nothing.
/// The check watches [myPermissionsProvider], so a member whose last gating
/// permission is revoked *while this is open* (a live role edit, a demotion)
/// sees the reason rather than a blank frame.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/admin_providers.dart';
import '../../../routing/routes.dart';
import '../widgets/settings_notice.dart';
import '../widgets/settings_panes.dart';
import '../widgets/space_settings_section.dart';
import 'settings_screen_scaffold.dart';

class SpaceSettingsScreen extends ConsumerWidget {
  const SpaceSettingsScreen({
    super.key,
    this.initialPaneId,
    this.onPaneChanged,
  });

  /// See [SettingsPanesScaffold.initialPaneId].
  final String? initialPaneId;

  /// See [SettingsPanesScaffold.onPaneChanged].
  final ValueChanged<String?>? onPaneChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permissions = ref.watch(myPermissionsProvider);
    if (!spaceSettingsReachable(permissions)) {
      return const SettingsScreenScaffold(
        title: 'Space settings',
        // Reached with go(), which replaces, so there is no stack to pop.
        backTooltip: 'Back to channels',
        backFallback: Routes.channels,
        child: SettingsNotice(
          message: 'None of your roles grant access to anything here.',
          detail: 'An administrator can grant you access.',
        ),
      );
    }
    return SettingsPanesScaffold(
      initialPaneId: initialPaneId,
      onPaneChanged: onPaneChanged,
      title: 'Space settings',
      backTooltip: 'Back to channels',
      backFallback: Routes.channels,
      groups: spaceSettingsPaneGroups(context, ref),
    );
  }
}
