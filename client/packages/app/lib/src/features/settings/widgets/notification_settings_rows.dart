// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rows inside [NotificationsSection] (`personal_status_sections.dart`)
/// that are each their own genuine round trip to the server, rather than a
/// bare toggle backed by local state: the lock-screen preview switch and the
/// account-wide notification preference. The notification schedule that used
/// to live here as `QuietHoursRow` is `notification_schedule_section.dart`
/// now - see `docs/decisions/0033-notification-schedule.md`.
///
/// Split out of personal_status_sections.dart purely to stay under this
/// repo's line budget.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/notification_preference_controller.dart';
import '../../../push/providers/push_content_preview_settings.dart';
import '../../../push/providers/push_controller.dart';
import '../../../widgets/run_guarded.dart';
import 'settings_select_row.dart';
import 'settings_toggle_row.dart';
import '../providers/settings_actions.dart';

/// The platforms that can open a sealed push preview.
const pushPreviewPlatforms = {TargetPlatform.iOS, TargetPlatform.android};

/// The "show message text on the lock screen" toggle.
///
/// Mobile only: iOS opens the sealed preview in its Notification Service
/// Extension and Android in its FCM background handler. Desktop and web have
/// no push preview to ask for.
class PushContentPreviewRow extends ConsumerWidget {
  const PushContentPreviewRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!pushPreviewPlatforms.contains(defaultTargetPlatform)) {
      return const SizedBox.shrink();
    }
    final enabled = ref.watch(pushContentPreviewSettingsProvider);

    return SettingsToggleRow(
      label: 'Message text on lock screen',
      description: 'On every device you use.',
      value: enabled ?? false,
      semanticLabel: 'Show message text on your lock screen',
      onChanged: enabled == null
          ? null
          : (value) async {
              await ref
                  .read(pushContentPreviewSettingsProvider.notifier)
                  .setEnabled(value);
              unawaited(ref.read(pushControllerProvider.notifier).register());
            },
    );
  }
}

/// Every preference offered in [NotificationPreferenceRow]'s select sheet,
/// each paired with its label.
const _notificationPreferenceOptions = <(api.NotificationPreference, String)>[
  (api.NotificationPreference.everything, 'All messages'),
  (api.NotificationPreference.mentions, 'Mentions and direct messages'),
  (api.NotificationPreference.nothing, 'Nothing'),
];

/// The "which messages wake a device" row inside `NotificationsSection`.
///
/// A real `GET` backs this (`GET /push/preference`), unlike presence
/// visibility, so the current value is read from the server rather than
/// echoed from the last local choice; see [notificationPreferenceProvider].
/// A server too old to have the route answers with an [api.NotFoundException],
/// read here as "not offered by this server" - the row disappears entirely
/// rather than offering a choice that would just 404 on every tap, the same
/// "no handler rather than a button that would just fail" treatment
/// `VoiceState.retryable` already established for a voice join button a 501
/// would only refuse the same way again.
///
/// A 404 reads as "not offered" above; any other fetch failure with nothing
/// cached is a different thing entirely, and stays "Unknown" forever with no
/// way back unless it is told apart from that case, so it renders its own
/// retryable error instead.
class NotificationPreferenceRow extends ConsumerStatefulWidget {
  const NotificationPreferenceRow({super.key});

  @override
  ConsumerState<NotificationPreferenceRow> createState() =>
      _NotificationPreferenceRowState();
}

class _NotificationPreferenceRowState
    extends ConsumerState<NotificationPreferenceRow>
    with GuardedActionState<NotificationPreferenceRow> {
  Future<void> _set(api.NotificationPreference preference) async {
    final container = ProviderScope.containerOf(context, listen: false);
    await guard(
      whatFailed: 'update your notification preference',
      action: () async {
        await container
            .read(settingsActionsProvider)
            .setNotificationPreference(preference);
        container.invalidate(notificationPreferenceProvider);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final preference = ref.watch(notificationPreferenceProvider);
    if (preference.hasError && preference.error is api.NotFoundException) {
      return const SizedBox.shrink();
    }
    // See this row's own doc comment for the 404-versus-everything-else split.
    final loadFailed = preference.hasError && preference.valueOrNull == null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsSelectRow<api.NotificationPreference>(
          label: 'Notify me for',
          sheetTitle: 'Notifications',
          value: preference.valueOrNull,
          choices: [
            for (final (value, label) in _notificationPreferenceOptions)
              SettingsChoice(value: value, label: label),
          ],
          onChanged: _set,
        ),
        if (loadFailed)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s8,
              0,
              AppSpacing.s8,
              AppSpacing.s8,
            ),
            child: AppErrorState(
              message: 'Could not load your notification preference.',
              onRetry: () => ref.invalidate(notificationPreferenceProvider),
            ),
          ),
        if (actionError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s8,
              0,
              AppSpacing.s8,
              AppSpacing.s8,
            ),
            child: AppErrorState(
              message: actionError!,
              onDismiss: clearActionError,
            ),
          ),
      ],
    );
  }
}
