// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether module sections (a level bar, say) draw on a member's profile card.
///
/// A per-user, per-device choice like the member-list badges, but on by
/// default because the profile card has always shown them.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/providers.dart';

const moduleProfileSectionsKey = 'slimm.modules.profile_sections_enabled';

class ModuleProfileSectionSettings extends Notifier<bool> {
  var _disposed = false;

  @override
  bool build() {
    ref.onDispose(() => _disposed = true);
    final loaded = ref.read(preferencesProvider).valueOrNull;
    if (loaded == null) _load();
    return loaded?.getBool(moduleProfileSectionsKey) ?? true;
  }

  Future<void> _load() async {
    final prefs = await ref.read(preferencesProvider.future);
    if (_disposed) return;
    state = prefs.getBool(moduleProfileSectionsKey) ?? true;
  }

  Future<void> setShown(bool shown) async {
    state = shown;
    final prefs = await ref.read(preferencesProvider.future);
    await prefs.setBool(moduleProfileSectionsKey, shown);
  }
}

final moduleProfileSectionSettingsProvider =
    NotifierProvider<ModuleProfileSectionSettings, bool>(
      ModuleProfileSectionSettings.new,
    );
