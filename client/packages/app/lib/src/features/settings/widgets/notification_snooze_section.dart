// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The snooze card: a 30m / 1h / until-tomorrow pause, or the active snooze
/// with its own cancel. Only offered while a notification schedule exists,
/// because the snooze is stored on that schedule.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/notification_schedule_controller.dart';
import '../../../widgets/run_guarded.dart';
import 'notification_schedule_write.dart';
import 'settings_section_header.dart';

class NotificationSnoozeSection extends ConsumerStatefulWidget {
  const NotificationSnoozeSection({super.key});

  @override
  ConsumerState<NotificationSnoozeSection> createState() =>
      _NotificationSnoozeSectionState();
}

class _NotificationSnoozeSectionState
    extends ConsumerState<NotificationSnoozeSection>
    with GuardedActionState<NotificationSnoozeSection> {
  Future<void> _snoozeFor(Duration duration) =>
      _apply(DateTime.now().add(duration).millisecondsSinceEpoch);

  Future<void> _snoozeUntilTomorrow() {
    final now = DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    return _apply(tomorrow.millisecondsSinceEpoch);
  }

  Future<void> _apply(int untilMs) => writeNotificationSchedule(
    ProviderScope.containerOf(context, listen: false),
    guard,
    whatFailed: 'snooze your notifications',
    write: (actions) => actions.setNotificationSnooze(untilMs).then((_) {}),
  );

  Future<void> _cancel() => writeNotificationSchedule(
    ProviderScope.containerOf(context, listen: false),
    guard,
    whatFailed: 'cancel your snooze',
    write: (actions) => actions.clearNotificationSnooze(),
  );

  @override
  Widget build(BuildContext context) {
    final schedule = ref.watch(notificationScheduleProvider).valueOrNull;
    if (schedule == null) return const SizedBox.shrink();
    final tokens = Theme.of(context).extension<AppTokens>()!;

    final Widget row;
    if (schedule.isSnoozed) {
      final until = TimeOfDay.fromDateTime(
        DateTime.fromMillisecondsSinceEpoch(schedule.snoozeUntil!),
      );
      row = AppListRow(
        leading: const Icon(AppIcons.notificationsOff),
        label: 'Snoozed until ${until.format(context)}',
        trailing: AppButton(
          label: 'Cancel',
          variant: AppButtonVariant.ghost,
          size: AppButtonSize.sm,
          onPressed: () => unawaited(_cancel()),
        ),
      );
    } else {
      row = Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s16,
          vertical: AppSpacing.s8,
        ),
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: AppSpacing.s8,
          spacing: AppSpacing.s12,
          children: [
            Text(
              'Snooze notifications for',
              style: AppText.ui.copyWith(color: tokens.textPrimary),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              spacing: AppSpacing.s8,
              children: [
                AppButton(
                  label: '30m',
                  size: AppButtonSize.sm,
                  variant: AppButtonVariant.secondary,
                  onPressed: () =>
                      unawaited(_snoozeFor(const Duration(minutes: 30))),
                ),
                AppButton(
                  label: '1h',
                  size: AppButtonSize.sm,
                  variant: AppButtonVariant.secondary,
                  onPressed: () =>
                      unawaited(_snoozeFor(const Duration(hours: 1))),
                ),
                AppButton(
                  label: 'Until tomorrow',
                  size: AppButtonSize.sm,
                  variant: AppButtonVariant.secondary,
                  onPressed: () => unawaited(_snoozeUntilTomorrow()),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return SettingsSectionCard(
      title: 'Snooze',
      children: [
        row,
        if (actionError != null)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s16),
            child: AppErrorState(
              message: actionError!,
              onDismiss: clearActionError,
            ),
          ),
      ],
    );
  }
}
