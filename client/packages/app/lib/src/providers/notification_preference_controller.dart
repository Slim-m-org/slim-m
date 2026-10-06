// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The caller's own notification preference: which messages are worth
/// waking a device for.
///
/// Unlike `presenceVisibilityDisplayProvider` (`presence_controller.dart`),
/// this needs no local-echo workaround: `GET /push/preference` is a genuine
/// round trip, not a per-viewer-derived answer, so the current value is
/// simply fetched.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import 'providers.dart';

/// The caller's current preference, fetched once and kept for the session.
///
/// Not `autoDispose`: the chime and the desktop banner read it for every
/// message (`message_alert_policy.dart`), and a refetch per message is not on.
/// It stays current through [ref.invalidate] from the settings row on a local
/// change and from the sync controller each time the socket comes back. A
/// [api.NotFoundException] here means the server predates the route, which the
/// settings row reads as "not offered by this server" rather than retrying a
/// request that would only 404 again; see `personal_status_sections.dart`'s
/// `_NotificationPreferenceRow`.
final notificationPreferenceProvider =
    FutureProvider<api.NotificationPreference>(
      (ref) => ref.watch(apiProvider).notificationPreference(),
    );
