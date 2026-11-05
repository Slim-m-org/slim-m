// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Operator alerts for someone who can manage the server.
///
/// `null` for everyone else, so a member never calls the route. The server
/// sends `admin_alerts.changed` only to an unmuted holder, and each one
/// re-reads the list.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../permissions.dart';
import '../../../providers/live_events.dart';
import '../../../providers/providers.dart';

final adminAlertsProvider = FutureProvider.autoDispose<api.AdminAlerts?>((
  ref,
) async {
  final me = await ref.watch(meProvider.future);
  if (!me.permissions.hasPermission(Perm.manageServer)) return null;
  final subscription = ref.watch(liveEventsProvider).listen((event) {
    if (event is api.AdminAlertsChanged) ref.invalidateSelf();
  });
  ref.onDispose(() => unawaited(subscription.cancel()));
  return ref.watch(apiProvider).fetchAdminAlerts();
});

/// Alerts the admin hid from the banner this session, by kind and subject.
final dismissedAdminAlertsProvider = StateProvider<Set<String>>((ref) => {});

String adminAlertKey(api.AdminAlert alert) => '${alert.kind}:${alert.subject}';

/// The open alerts the banner should show: unmuted and not dismissed.
final bannerAdminAlertsProvider = Provider.autoDispose<List<api.AdminAlert>>((
  ref,
) {
  final alerts = ref.watch(adminAlertsProvider).valueOrNull;
  if (alerts == null || alerts.muted) return const [];
  final dismissed = ref.watch(dismissedAdminAlertsProvider);
  return [
    for (final alert in alerts.open)
      if (!dismissed.contains('${adminAlertKey(alert)}@${alert.raisedAt}'))
        alert,
  ];
});

/// Saves the caller's mute, then re-reads the list so the switch shows what the server holds.
Future<void> setAdminAlertsMuted(WidgetRef ref, bool muted) async {
  try {
    await ref.read(apiProvider).setAdminAlertsMuted(muted);
  } catch (error, stack) {
    api.AppLog.swallowed(
      api.LogTag.ui,
      'Could not change the alert mute; the list reloads from the server',
      error,
      stack,
    );
  }
  ref.invalidate(adminAlertsProvider);
}

/// Hides [alerts] until they recover and open again.
void dismissAdminAlerts(WidgetRef ref, List<api.AdminAlert> alerts) {
  ref.read(dismissedAdminAlertsProvider.notifier).state = {
    ...ref.read(dismissedAdminAlertsProvider),
    for (final alert in alerts) '${adminAlertKey(alert)}@${alert.raisedAt}',
  };
}
