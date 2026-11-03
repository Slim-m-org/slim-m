// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where module output shows for every member, set by an admin for the Space.
///
/// Read from `/version`, which every member can read, and re-read when the
/// server says the setting changed.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/live_events.dart';
import '../../settings/providers/settings_actions.dart';

final moduleDisplayProvider = FutureProvider.autoDispose<api.Version>((ref) {
  final sub = ref
      .watch(liveEventsProvider)
      .where((e) => e is api.SpaceSettingsChanged)
      .listen((_) => ref.invalidateSelf());
  ref.onDispose(sub.cancel);
  return ref.watch(settingsActionsProvider).version();
});

/// Module badges beside names in the member list; off until an admin turns them on.
final moduleMemberBadgesShownProvider = Provider.autoDispose<bool>(
  (ref) => ref.watch(
    moduleDisplayProvider.select(
      (v) => v.valueOrNull?.moduleMemberBadges ?? false,
    ),
  ),
);

/// Module sections on profile cards; on until an admin turns them off.
final moduleProfileSectionsShownProvider = Provider.autoDispose<bool>(
  (ref) => ref.watch(
    moduleDisplayProvider.select(
      (v) => v.valueOrNull?.moduleProfileSections ?? true,
    ),
  ),
);
