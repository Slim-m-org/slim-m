// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A conversation row's one Notifications entry, and the menu it opens with
/// mute, mentions only and off hours: beside the row on a wide window, a
/// sheet on a compact one.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../members/widgets/member_profile_popover.dart'
    show AnchoredMemberPopover;
import '../providers/channel_notification_overrides_controller.dart';
import 'row_menu_notifications.dart';

/// The short word the Notifications entry shows beside its name.
String notificationStateLabel(api.NotificationPreference? current) =>
    switch (current) {
      api.NotificationPreference.nothing => 'Muted',
      api.NotificationPreference.mentions => 'Mentions',
      api.NotificationPreference.everything => 'All',
      null => 'Default',
    };

/// Wrapped so the submenu can open beside this very entry, where the row menu
/// it replaces stood.
Widget notificationsMenuItem(
  BuildContext context,
  ProviderContainer container,
  String channelId,
  VoidCallback close, {
  required String muteLabel,
  api.NotificationPreference? channelDefault,
}) {
  final tokens = Theme.of(context).extension<AppTokens>()!;
  final current = container
      .read(channelNotificationOverridesProvider)
      .overrideFor(channelId);
  return Builder(
    builder: (itemContext) => AppMenuItem(
      label: 'Notifications',
      leading: current == api.NotificationPreference.nothing
          ? AppIcons.notificationsOff
          : AppIcons.notificationsOn,
      trailing: Text(
        notificationStateLabel(current),
        style: AppText.caption.copyWith(color: tokens.textSecondary),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      submenu: true,
      onTap: () {
        final entry = _entryRect(itemContext);
        close();
        unawaited(
          _showNotificationsMenu(
            context,
            container,
            channelId,
            entry,
            muteLabel: muteLabel,
            channelDefault: channelDefault,
          ),
        );
      },
    ),
  );
}

Rect? _entryRect(BuildContext itemContext) {
  final box = itemContext.findRenderObject() as RenderBox?;
  final overlay =
      Overlay.of(itemContext).context.findRenderObject() as RenderBox?;
  if (box == null || overlay == null) return null;
  return box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
}

Future<void> _showNotificationsMenu(
  BuildContext anchor,
  ProviderContainer container,
  String channelId,
  Rect? entry, {
  required String muteLabel,
  api.NotificationPreference? channelDefault,
}) {
  List<Widget> items(BuildContext menuContext) => notificationMenuItems(
    anchor,
    container,
    channelId,
    () => Navigator.of(menuContext).pop(),
    muteLabel: muteLabel,
    channelDefault: channelDefault,
  );

  if (MediaQuery.sizeOf(anchor).width < kCompactWidth) {
    return showAppSheet<void>(
      anchor,
      builder: (context) => AppSheetMenu(children: items(context)),
    );
  }
  return showGeneralDialog<void>(
    context: anchor,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.transparent,
    transitionDuration: AppMotion.reduced(anchor, AppMotion.base),
    pageBuilder: (context, _, _) => AnchoredMemberPopover(
      origin: entry?.topLeft ?? Offset.zero,
      anchorSize: entry?.size ?? Size.zero,
      child: AppMenu(children: items(context)),
    ),
    transitionBuilder: (context, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
  );
}
