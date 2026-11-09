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
import '../../../widgets/run_guarded.dart';
import 'settings_info_line.dart';
import 'settings_hairline.dart';
import 'settings_section_header.dart';
import 'settings_select_row.dart';
import 'settings_toggle_row.dart';
import '../providers/settings_actions.dart';

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

typedef _Draft = ({
  List<api.NotificationScheduleDay> days,
  api.OffHoursMode mode,
});

api.NotificationScheduleDay _day(int weekday, TimeOfDay start, TimeOfDay end) =>
    api.NotificationScheduleDay(
      weekday: weekday,
      startMinute: start.hour * 60 + start.minute,
      endMinute: end.hour * 60 + end.minute,
    );

TimeOfDay _atMinute(int minute) =>
    TimeOfDay(hour: minute ~/ 60, minute: minute % 60);

class _NotificationScheduleSectionState
    extends ConsumerState<NotificationScheduleSection>
    with GuardedActionState<NotificationScheduleSection> {
  /// What the person asked for and the server has not confirmed yet. Shown at
  /// once, so quick taps stack on each other instead of overwriting.
  _Draft? _draft;
  bool _flushing = false;

  Future<bool> _save(_Draft draft) async {
    final String timezone;
    try {
      timezone = await ref.read(deviceTimezoneProvider.future);
    } on Object catch (error, stack) {
      api.reportFailure(
        api.LogTag.platform,
        'read the device time zone',
        error,
        stack,
      );
      setActionError(
        'Could not update your notification schedule. This device did not '
        'say which time zone it is in.',
      );
      return false;
    }
    return guard(
      whatFailed: 'update your notification schedule',
      action: () => ref
          .read(settingsActionsProvider)
          .setNotificationSchedule(
            timezone: timezone,
            offHoursMode: draft.mode,
            days: draft.days,
          ),
    );
  }

  Future<void> _toggle(bool enabled) async {
    if (!enabled) {
      final ok = await guard(
        whatFailed: 'turn off your notification schedule',
        action: () =>
            ref.read(settingsActionsProvider).clearNotificationSchedule(),
      );
      if (ok) ref.invalidate(notificationScheduleProvider);
      return;
    }
    final ok = await _save((
      days: [
        for (final weekday in _defaultWeekdays)
          _day(weekday, _defaultStart, _defaultEnd),
      ],
      mode: api.OffHoursMode.mentions,
    ));
    if (ok) ref.invalidate(notificationScheduleProvider);
  }

  void _edit(api.NotificationSchedule current, _Draft Function(_Draft) change) {
    final basis = _draft ?? (days: current.days, mode: current.offHoursMode);
    setState(() => _draft = change(basis));
    unawaited(_flush());
  }

  Future<void> _flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      for (var target = _draft; target != null; target = _draft) {
        final ok = await _save(target);
        if (!mounted) return;
        if (ok) await _refetch();
        if (!mounted) return;
        if (!ok || identical(_draft, target)) setState(() => _draft = null);
      }
    } finally {
      _flushing = false;
    }
  }

  /// Waits for the saved schedule to come back, so the draft is not dropped
  /// in favour of the old one for a round trip.
  Future<void> _refetch() async {
    try {
      ref.invalidate(notificationScheduleProvider);
      await ref.read(notificationScheduleProvider.future);
    } on Object {
      // The section shows its own load error; this only waits for an answer.
    }
  }

  void _toggleDay(
    int weekday,
    api.NotificationSchedule current,
    TimeOfDay start,
    TimeOfDay end,
  ) {
    _edit(current, (basis) {
      final kept = [
        for (final day in basis.days)
          if (day.weekday != weekday) day,
      ];
      final added = kept.length == basis.days.length;
      return (
        days: [...kept, if (added) _day(weekday, start, end)]
          ..sort((a, b) => a.weekday.compareTo(b.weekday)),
        mode: basis.mode,
      );
    });
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
    if (pickedEnd == null || !mounted) return;
    _edit(current, (basis) {
      return (
        days: [
          for (final day in basis.days)
            _day(day.weekday, pickedStart, pickedEnd),
        ],
        mode: basis.mode,
      );
    });
  }

  void _setMode(api.OffHoursMode mode, api.NotificationSchedule current) {
    _edit(current, (basis) => (days: basis.days, mode: mode));
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
    final shown = current == null
        ? null
        : (_draft ?? (days: current.days, mode: current.offHoursMode));

    // The window shown for editing: the first configured day's, or the default for a schedule with every day off.
    final firstDay = shown?.days.firstOrNull;
    final start = firstDay == null
        ? _defaultStart
        : _atMinute(firstDay.startMinute);
    final end = firstDay == null ? _defaultEnd : _atMinute(firstDay.endMinute);
    final activeWeekdays =
        shown?.days.map((d) => d.weekday).toSet() ?? const {};

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
          onChanged: schedule.isLoading || _flushing ? null : _toggle,
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
            value: shown!.mode,
            choices: const [
              SettingsChoice(
                value: api.OffHoursMode.mentions,
                label: 'Mentions and direct messages',
              ),
              SettingsChoice(value: api.OffHoursMode.nothing, label: 'Nothing'),
            ],
            onChanged: (mode) => _setMode(mode, current),
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
