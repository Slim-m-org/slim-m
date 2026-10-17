// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The notification schedule (`docs/decisions/0033-notification-schedule.md`):
/// replaces [QuietHoursRow]'s single daily window with a per-weekday one,
/// evaluated in the device's own IANA zone, plus an off-hours policy, two
/// allow-lists, and a snooze.
///
/// One shared start/end time applies to every weekday this account turns
/// on, rather than a different window per day: the owner's own request
/// ("my defined hours") and Slack's own default schedule are both a single
/// daily window with a day-of-week on/off choice, not seven independent
/// windows, so this is the scope that actually matches the ask rather than
/// building a grid nobody asked to fill in seven times over.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/device_timezone.dart';
import '../providers/notification_schedule_controller.dart';
import '../providers/providers.dart';
import 'run_guarded.dart';
import 'settings_info_line.dart';
import 'settings_hairline.dart';
import 'settings_section_header.dart';
import 'settings_select_row.dart';
import 'settings_toggle_row.dart';

const _dayLabels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
const _dayFullNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

const _defaultStart = TimeOfDay(hour: 9, minute: 0);
const _defaultEnd = TimeOfDay(hour: 17, minute: 0);

/// Weekdays a fresh schedule starts with: the ordinary working week, the
/// same "give it a sensible starting shape" reasoning `QuietHoursRow`'s own
/// default window uses.
const _defaultWeekdays = {0, 1, 2, 3, 4};

class NotificationScheduleSection extends ConsumerStatefulWidget {
  const NotificationScheduleSection({super.key});

  @override
  ConsumerState<NotificationScheduleSection> createState() =>
      _NotificationScheduleSectionState();
}

class _NotificationScheduleSectionState
    extends ConsumerState<NotificationScheduleSection>
    with GuardedActionState<NotificationScheduleSection> {
  Future<void> _save({
    required Set<int> weekdays,
    required TimeOfDay start,
    required TimeOfDay end,
    required api.OffHoursMode mode,
  }) async {
    final timezone = await ref.read(deviceTimezoneProvider.future);
    final startMinute = start.hour * 60 + start.minute;
    final endMinute = end.hour * 60 + end.minute;
    final ok = await guard(
      whatFailed: 'update your notification schedule',
      action: () => ref
          .read(apiProvider)
          .setNotificationSchedule(
            timezone: timezone,
            offHoursMode: mode,
            days: [
              for (final weekday in weekdays)
                api.NotificationScheduleDay(
                  weekday: weekday,
                  startMinute: startMinute,
                  endMinute: endMinute,
                ),
            ],
          ),
    );
    if (ok) ref.invalidate(notificationScheduleProvider);
  }

  Future<void> _toggle(bool enabled, api.NotificationSchedule? current) async {
    if (!enabled) {
      final ok = await guard(
        whatFailed: 'turn off your notification schedule',
        action: () => ref.read(apiProvider).clearNotificationSchedule(),
      );
      if (ok) ref.invalidate(notificationScheduleProvider);
      return;
    }
    await _save(
      weekdays: _defaultWeekdays,
      start: _defaultStart,
      end: _defaultEnd,
      mode: api.OffHoursMode.mentions,
    );
  }

  Future<void> _toggleDay(
    int weekday,
    api.NotificationSchedule current,
    TimeOfDay start,
    TimeOfDay end,
  ) async {
    final weekdays = current.days.map((d) => d.weekday).toSet();
    if (!weekdays.remove(weekday)) weekdays.add(weekday);
    await _save(
      weekdays: weekdays,
      start: start,
      end: end,
      mode: current.offHoursMode,
    );
  }

  Future<void> _pickHours(
    api.NotificationSchedule current,
    TimeOfDay start,
    TimeOfDay end,
  ) async {
    final pickedStart = await showAppTimePicker(
      context: context,
      initialTime: start,
    );
    if (pickedStart == null || !mounted) return;
    final pickedEnd = await showAppTimePicker(
      context: context,
      initialTime: end,
    );
    if (pickedEnd == null) return;
    await _save(
      weekdays: current.days.map((d) => d.weekday).toSet(),
      start: pickedStart,
      end: pickedEnd,
      mode: current.offHoursMode,
    );
  }

  Future<void> _setMode(
    api.OffHoursMode mode,
    api.NotificationSchedule current,
    TimeOfDay start,
    TimeOfDay end,
  ) async {
    await _save(
      weekdays: current.days.map((d) => d.weekday).toSet(),
      start: start,
      end: end,
      mode: mode,
    );
  }

  @override
  Widget build(BuildContext context) {
    final schedule = ref.watch(notificationScheduleProvider);
    if (schedule.hasError && schedule.error is api.NotFoundException) {
      return const SizedBox.shrink();
    }
    final loadFailed = schedule.hasError && schedule.valueOrNull == null;
    final current = schedule.valueOrNull;
    final enabled = current != null;

    // The window shown for editing: the first configured day's, or the default for a schedule with every day off.
    final firstDay = current?.days.isNotEmpty ?? false
        ? current!.days.first
        : null;
    final start = firstDay == null
        ? _defaultStart
        : TimeOfDay(
            hour: firstDay.startMinute ~/ 60,
            minute: firstDay.startMinute % 60,
          );
    final end = firstDay == null
        ? _defaultEnd
        : TimeOfDay(
            hour: firstDay.endMinute ~/ 60,
            minute: firstDay.endMinute % 60,
          );
    final activeWeekdays =
        current?.days.map((d) => d.weekday).toSet() ?? const {};

    final tokens = Theme.of(context).extension<AppTokens>()!;
    final hours = Text(
      '${start.format(context)} - ${end.format(context)}',
      style: AppText.caption.copyWith(
        fontFamily: AppFonts.mono,
        color: tokens.textPrimary,
      ),
    );
    return SettingsRowGroup(
      children: [
        SettingsToggleRow(
          label: 'Notification schedule',
          description: 'Only notify during the hours you set.',
          value: enabled,
          onChanged: schedule.isLoading ? null : (v) => _toggle(v, current),
          semanticLabel: 'Notification schedule',
        ),
        if (enabled) ...[
          SettingsSubRow(
            label: 'Days',
            // Scaled down rather than clipped: seven chips overflow a phone-width card.
            trailing: Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Row(
                  spacing: 6,
                  children: [
                    for (var weekday = 0; weekday < 7; weekday++)
                      _DayToggle(
                        label: _dayLabels[weekday],
                        semanticLabel: _dayFullNames[weekday],
                        active: activeWeekdays.contains(weekday),
                        onTap: () => _toggleDay(weekday, current, start, end),
                      ),
                  ],
                ),
              ),
            ),
          ),
          SettingsSubRow(
            label: 'Hours',
            semanticLabel:
                'Hours, ${start.format(context)} to ${end.format(context)}',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: AppSpacing.s8,
              children: [
                hours,
                Icon(
                  AppIcons.chevronDown,
                  size: AppSizes.icon16,
                  color: tokens.textSecondary,
                ),
              ],
            ),
            onTap: () => _pickHours(current, start, end),
          ),
          SettingsSelectRow<api.OffHoursMode>(
            sub: true,
            label: 'Outside these hours',
            sheetTitle: 'Outside your notification schedule',
            value: current.offHoursMode,
            choices: const [
              SettingsChoice(
                value: api.OffHoursMode.mentions,
                label: 'Mentions and direct messages',
              ),
              SettingsChoice(value: api.OffHoursMode.nothing, label: 'Nothing'),
            ],
            onChanged: (mode) => _setMode(mode, current, start, end),
          ),
          const SettingsInfoLine(
            'Calls still ring even outside your hours; only chat '
            'notifications follow this schedule.',
            tinted: true,
          ),
        ],
        if (loadFailed)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s16),
            child: AppErrorState(
              message: 'Could not load your notification schedule.',
              onRetry: () => ref.invalidate(notificationScheduleProvider),
            ),
          ),
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

class _DayToggle extends StatelessWidget {
  const _DayToggle({
    required this.label,
    required this.semanticLabel,
    required this.active,
    required this.onTap,
  });

  final String label;
  final String semanticLabel;
  final bool active;
  final VoidCallback onTap;

  static const _size = 32.0;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return FocusableTapTarget(
      onTap: onTap,
      toggled: active,
      semanticLabel: '$semanticLabel, ${active ? 'on' : 'off'}',
      ringRadius: AppRadii.full,
      builder: (context, focused, hovered) => Container(
        width: _size,
        height: _size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? tokens.textPrimary : Colors.transparent,
          shape: BoxShape.circle,
          border: active ? null : Border.all(color: tokens.borderSubtle),
        ),
        child: Text(
          label,
          style: AppText.micro.copyWith(
            color: active ? tokens.surfaceBase : tokens.textSecondary,
            fontWeight: active ? AppWeights.semi : AppWeights.regular,
          ),
        ),
      ),
    );
  }
}
