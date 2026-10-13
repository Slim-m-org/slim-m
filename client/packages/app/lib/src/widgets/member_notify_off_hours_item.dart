// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The member card's "notify me about this person off hours" row, split out
/// of `member_profile.dart` purely to stay under this repo's line budget.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/notification_schedule_controller.dart';
import 'member_actions.dart';

class MemberNotifyOffHoursItem extends ConsumerWidget {
  const MemberNotifyOffHoursItem({
    super.key,
    required this.host,
    required this.profile,
    required this.run,
  });

  final BuildContext host;
  final api.UserProfile profile;
  final void Function(Future<void> Function(ProviderContainer container)) run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allowedOffHours =
        ref
            .watch(notificationScheduleProvider)
            .valueOrNull
            ?.allowedUserIds
            .contains(profile.id) ??
        false;
    return AppMenuItem(
      label: allowedOffHours
          ? 'Stop off-hours notifications'
          : 'Notify me off hours',
      leading: allowedOffHours
          ? AppIcons.notificationsOff
          : AppIcons.notificationsOn,
      onTap: () => run(
        (container) => toggleNotificationScheduleAllowedUser(
          host,
          container,
          profile,
          allowedOffHours,
        ),
      ),
    );
  }
}
