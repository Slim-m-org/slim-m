// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rail header's chevron menu: read-state, saved messages and Space settings.
/// Channel creation lives in the rail's blank-space menu and category headers.
///
/// Its own file so `channel_rail_frame.dart` carries the rail's fixed bars
/// rather than also carrying an overlay menu's wiring.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/admin_providers.dart';
import '../routing/routes.dart';
import 'anchored_menu.dart';
import 'animated_menu_portal.dart';
import 'row_menu_notifications.dart';
import 'saved_messages_sheet.dart';
import 'space_settings_section.dart';

/// Every member gets it; "Space settings" only with a bit in [spaceSettingsReachable].
class SpaceMenuButton extends ConsumerStatefulWidget {
  const SpaceMenuButton({super.key});

  @override
  ConsumerState<SpaceMenuButton> createState() => _SpaceMenuButtonState();
}

class _SpaceMenuButtonState extends ConsumerState<SpaceMenuButton> {
  final _controller = AnimatedMenuController();

  @override
  Widget build(BuildContext context) {
    final permissions = ref.watch(myPermissionsProvider);

    return AnchoredMenu(
      controller: _controller,
      menu: AppMenu(
        width: 200,
        children: [
          markSpaceReadMenuItem(
            context,
            ProviderScope.containerOf(context, listen: false),
            _controller.hide,
          ),
          // Above settings and outside the manage gate: keeping messages is something every member does.
          AppMenuItem(
            label: 'Saved messages',
            leading: AppIcons.bookmark,
            onTap: () {
              _controller.hide();
              showSavedMessagesSheet(context);
            },
          ),
          // Settings stays behind the gate that makes its screen worth opening.
          if (spaceSettingsReachable(permissions))
            AppMenuItem(
              label: 'Space settings',
              leading: AppIcons.settings,
              onTap: () {
                _controller.hide();
                context.push(Routes.spaceSettings);
              },
            ),
        ],
      ),
      child: AppIconButton(
        icon: AppIcons.chevronDown,
        semanticLabel: 'Space menu',
        onPressed: _controller.toggle,
      ),
    );
  }
}
