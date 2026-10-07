// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rail header's chevron: Space settings, plus channel creation
/// (backlog item 55 - creation moved here from a header "+" that had no
/// label explaining what it was for).
///
/// Its own file so `channel_rail_frame.dart` carries the rail's fixed bars
/// rather than also carrying an overlay menu's wiring.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';

import '../permissions.dart';
import '../providers/admin_providers.dart';
import '../providers/channel_notification_overrides_controller.dart';
import '../routing/routes.dart';
import 'anchored_menu.dart';
import 'animated_menu_portal.dart';
import 'create_category_sheet.dart';
import 'create_channel_sheet.dart';
import 'mark_read_action.dart';
import 'row_menu_notifications.dart';
import 'saved_messages_sheet.dart';
import 'space_settings_section.dart';
import '../action_labels.dart';

/// Every member gets it: "Saved messages" and "Mark all as read" are theirs
/// regardless of role. "Space settings" is offered only to a caller holding
/// one of [spaceSettingsReachable]'s gating bits, so no member is sent to that
/// screen empty. "Add channel" and "Add category" are gated separately, on
/// [Perm.manageChannels] specifically - the same bit the rail's own channel
/// rows already require to be dragged and reordered - so a moderator who can
/// see reports but not manage channels sees the menu without those two items
/// rather than either item 403ing.
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
    final canManageChannels = permissions.hasPermission(Perm.manageChannels);

    return AnchoredMenu(
      controller: _controller,
      menu: AppMenu(
        width: 200,
        children: [
          if (canManageChannels) ...[
            AppMenuItem(
              label: ActionLabels.createChannel,
              leading: AppIcons.add,
              onTap: () {
                _controller.hide();
                showCreateChannelSheet(context, initialKind: 'text');
              },
            ),
            AppMenuItem(
              label: ActionLabels.createCategory,
              leading: AppIcons.add,
              onTap: () {
                _controller.hide();
                showCreateCategorySheet(context);
              },
            ),
          ],
          _MarkAllReadEntry(close: _controller.hide),
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

/// The space-wide Mark all as read, absent when nothing is unread. Its own
/// widget so the channel list is watched only while the menu is open, not for
/// as long as the rail shows the button.
class _MarkAllReadEntry extends ConsumerWidget {
  const _MarkAllReadEntry({required this.close});

  final VoidCallback close;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watched so the entry appears and goes with the badges it clears.
    ref.watch(channelNotificationOverridesProvider);
    final entry = markAllReadMenuItem(
      context,
      ProviderScope.containerOf(context, listen: false),
      ref.watch(spaceChannelsProvider).valueOrNull ?? const [],
      close,
    );
    return entry ?? const SizedBox.shrink();
  }
}
