// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where module output shows for every member, set by an admin for the Space.
///
/// Read from `/version`, which every member can read, and re-read when the
/// server says the setting changed.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/live_events.dart';
import '../../../providers/providers.dart';
import '../../settings/providers/settings_actions.dart';

final moduleDisplayProvider = FutureProvider<api.Version>((ref) {
  final sub = ref
      .watch(liveEventsProvider)
      .where((e) => e is api.SpaceSettingsChanged)
      .listen((_) => ref.invalidateSelf());
  ref.onDispose(sub.cancel);
  return ref.watch(settingsActionsProvider).version();
});

const moduleMemberBadgesKey = 'slimm.modules.show_member_badges';
const moduleProfileSectionsKey = 'slimm.modules.show_profile_sections';

/// One person's own switch, on until they turn it off; kept per Space and device.
class PersonalModuleDisplay extends Notifier<bool> {
  PersonalModuleDisplay(this.key);

  final String key;
  var _disposed = false;

  @override
  bool build() {
    ref.onDispose(() => _disposed = true);
    final loaded = ref.read(preferencesProvider).valueOrNull;
    if (loaded == null) _load();
    return loaded?.getBool(key) ?? true;
  }

  Future<void> _load() async {
    final prefs = await ref.read(preferencesProvider.future);
    if (_disposed) return;
    state = prefs.getBool(key) ?? true;
  }

  Future<void> setShown(bool shown) async {
    state = shown;
    final prefs = await ref.read(preferencesProvider.future);
    await prefs.setBool(key, shown);
  }
}

final personalMemberBadgesProvider =
    NotifierProvider<PersonalModuleDisplay, bool>(
      () => PersonalModuleDisplay(moduleMemberBadgesKey),
    );

final personalProfileSectionsProvider =
    NotifierProvider<PersonalModuleDisplay, bool>(
      () => PersonalModuleDisplay(moduleProfileSectionsKey),
    );

/// What the Space allows, which a personal switch can only narrow.
final spaceMemberBadgesProvider = Provider<bool>(
  (ref) => ref.watch(
    moduleDisplayProvider.select(
      (v) => v.valueOrNull?.moduleMemberBadges ?? false,
    ),
  ),
);

final spaceProfileSectionsProvider = Provider<bool>(
  (ref) => ref.watch(
    moduleDisplayProvider.select(
      (v) => v.valueOrNull?.moduleProfileSections ?? true,
    ),
  ),
);

/// Module badges beside names in the member list: the Space allows them and this person has not hidden them.
final moduleMemberBadgesShownProvider = Provider<bool>(
  (ref) =>
      ref.watch(spaceMemberBadgesProvider) &&
      ref.watch(personalMemberBadgesProvider),
);

/// Module sections on profile cards: the Space allows them and this person has not hidden them.
final moduleProfileSectionsShownProvider = Provider<bool>(
  (ref) =>
      ref.watch(spaceProfileSectionsProvider) &&
      ref.watch(personalProfileSectionsProvider),
);
