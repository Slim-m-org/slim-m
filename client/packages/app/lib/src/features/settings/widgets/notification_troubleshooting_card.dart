// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Notifications card on the Troubleshooting pane: a test alert and, on an
/// iPhone, a push re-registration.
library;

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart'
    show LocalAlertChannel, isAndroidHost, isLinuxHost;

import '../../../providers/toasts.dart';
import '../../../push/providers/push_controller.dart';
import '../../../push/providers/push_reset.dart';
import 'settings_section_header.dart';

class NotificationTroubleshootingCard extends StatelessWidget {
  const NotificationTroubleshootingCard({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsSectionCard(
      title: 'Notifications',
      children: [
        const TestNotificationRow(),
        if (defaultTargetPlatform == TargetPlatform.iOS && !kIsWeb)
          const ResetPushRow(),
      ],
    );
  }
}

/// A button that posts a local notification straight away, so someone can
/// confirm slim-m's notifications reach their OS - most useful on the Linux
/// desktop, where there is no remote push to fall back on and a silent
/// failure is otherwise invisible.
class TestNotificationRow extends ConsumerStatefulWidget {
  const TestNotificationRow({super.key});

  // Only where a local notification actually displays (Android, Linux desktop); a pipe test via the same LocalNotifications.show path a real alert uses.
  static bool get _supported => isAndroidHost || isLinuxHost;

  @override
  ConsumerState<TestNotificationRow> createState() =>
      _TestNotificationRowState();
}

class _TestNotificationRowState extends ConsumerState<TestNotificationRow> {
  bool _sending = false;
  String? _error;

  Future<void> _send() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await ref
          .read(localNotificationsProvider)
          .show(
            'Test notification - if you can see this, slim-m can '
            'reach your notifications.',
            channel: LocalAlertChannel.messages,
          );
      if (!mounted) return;
      ref.read(toastsProvider.notifier).show('Test notification sent.');
    } catch (e, stack) {
      api.reportFailure(
        api.LogTag.platform,
        'show the test notification',
        e,
        stack,
      );
      if (mounted) setState(() => _error = _failureSentence);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  static const _failureSentence =
      'Could not show the test notification. Check that your system allows '
      'notifications from slim-m.';

  @override
  Widget build(BuildContext context) {
    final error = _error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppListRow(
          label: 'Test notification',
          subtitle: 'Check that notifications reach you.',
          trailing: AppButton(
            label: 'Send test',
            size: AppButtonSize.sm,
            variant: AppButtonVariant.secondary,
            onPressed: TestNotificationRow._supported && !_sending
                ? _send
                : null,
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s16),
            child: AppErrorState(
              message: error,
              onDismiss: () => setState(() => _error = null),
            ),
          ),
      ],
    );
  }
}

/// Re-registers this iPhone for push from scratch, for a phone that stopped
/// getting notifications while every setting says they are on.
class ResetPushRow extends ConsumerStatefulWidget {
  const ResetPushRow({super.key});

  @override
  ConsumerState<ResetPushRow> createState() => ResetPushRowState();
}

class ResetPushRowState extends ConsumerState<ResetPushRow> {
  bool _resetting = false;

  Future<void> _reset() async {
    setState(() => _resetting = true);
    final reset = await resetPushRegistration(ref);
    if (!mounted) return;
    setState(() => _resetting = false);
    ref
        .read(toastsProvider.notifier)
        .show(reset ? 'Notifications reset.' : 'Nothing to reset here.');
  }

  @override
  Widget build(BuildContext context) {
    return AppListRow(
      label: 'Reset notifications',
      subtitle: 'Try this if notifications stopped arriving on this phone.',
      trailing: AppButton(
        label: _resetting ? 'Resetting' : 'Reset',
        size: AppButtonSize.sm,
        variant: AppButtonVariant.secondary,
        onPressed: _resetting ? null : _reset,
      ),
    );
  }
}
