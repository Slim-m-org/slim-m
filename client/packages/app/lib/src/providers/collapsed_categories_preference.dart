// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which channel categories this device has folded in the rail (design
/// review note 8/2). Per device, the same shape `auto_update_preference.dart`
/// already gives a single stored answer - a category id is globally unique,
/// so one flat set covers every Space this install ever opens.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'providers.dart';

const collapsedCategoriesKey = 'slimm.rail.collapsed_categories';

/// Read directly (not through the provider), the same seam
/// [loadAutoUpdatePreference] gives a caller that already holds the prefs.
Set<String> loadCollapsedCategories(SharedPreferences prefs) =>
    prefs.getStringList(collapsedCategoriesKey)?.toSet() ?? const {};

class CollapsedCategoriesController extends StateNotifier<Set<String>> {
  CollapsedCategoriesController(this._ref) : super(const {}) {
    _load();
  }

  final Ref _ref;

  /// Whichever of the constructor's load or a first toggle reads the stored
  /// set first; a toggle must start from it, not from the empty placeholder.
  bool _loaded = false;

  Future<void> _load() async {
    final prefs = await _ref.read(preferencesProvider.future);
    _adoptStored(prefs);
  }

  void _adoptStored(SharedPreferences prefs) {
    if (_loaded || !mounted) return;
    _loaded = true;
    state = loadCollapsedCategories(prefs);
  }

  Future<void> toggle(String categoryId) async {
    final prefs = await _ref.read(preferencesProvider.future);
    _adoptStored(prefs);
    final next = {...state};
    if (!next.remove(categoryId)) next.add(categoryId);
    state = next;
    await prefs.setStringList(collapsedCategoriesKey, next.toList());
  }
}

final collapsedCategoriesProvider =
    StateNotifierProvider<CollapsedCategoriesController, Set<String>>(
      CollapsedCategoriesController.new,
    );
