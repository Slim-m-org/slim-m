// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The server's own identity and capability flags, from `/version`.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../features/settings/providers/settings_actions.dart';

/// There is no separate per-deployment "workspace name", so the name is `/version`'s `space_name`.
///
/// It must not watch the live events: the sync controller reads this provider, and the cycle would trip riverpod. The event applier invalidates it instead.
final serverInfoProvider = FutureProvider.autoDispose<api.Version>(
  (ref) => ref.watch(settingsActionsProvider).version(),
);

/// Refetches [serverInfoProvider] when the socket goes live.
///
/// A reconnect always refetches, since a redeploy or a rename made while offline sends no frame to replay; the first connect only retries a failed first fetch.
void refreshServerInfo(Ref ref, {required bool reconnect}) {
  if (!ref.exists(serverInfoProvider)) return;
  if (reconnect || ref.read(serverInfoProvider).hasError) {
    ref.invalidate(serverInfoProvider);
  }
}
