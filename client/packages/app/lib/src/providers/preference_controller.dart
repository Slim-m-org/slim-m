// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one shape a single-choice preference stored in shared preferences takes:
/// the default holds until [restore] finds a usable stored value, and [select]
/// applies a choice before it persists it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

/// A controller bootstrap restores before the first frame.
abstract interface class RestorablePreference {
  Future<void> restore();
}

/// A preference chosen from the values of an enum, stored by name.
///
/// A missing, unrecognised or unreadable stored value leaves [fallback] in
/// place: a choice a later version dropped must not throw on an older one.
abstract class EnumPreferenceController<T extends Enum> extends StateNotifier<T>
    implements RestorablePreference {
  EnumPreferenceController(
    this.ref, {
    required this.storageKey,
    required this.choices,
    required T fallback,
  }) : super(fallback);

  final Ref ref;
  final String storageKey;
  final List<T> choices;

  @override
  Future<void> restore() async {
    try {
      final prefs = await ref.read(preferencesProvider.future);
      final stored = prefs.getString(storageKey);
      for (final choice in choices) {
        if (choice.name == stored) {
          state = choice;
          return;
        }
      }
    } catch (_) {
      // The fallback is always a usable answer.
    }
  }

  Future<void> select(T choice) async {
    state = choice;
    final prefs = await ref.read(preferencesProvider.future);
    await prefs.setString(storageKey, choice.name);
  }
}

/// An on/off preference, off unless stored otherwise.
abstract class BoolPreferenceController extends StateNotifier<bool>
    implements RestorablePreference {
  BoolPreferenceController(this.ref, {required this.storageKey}) : super(false);

  final Ref ref;
  final String storageKey;

  @override
  Future<void> restore() async {
    try {
      final prefs = await ref.read(preferencesProvider.future);
      state = prefs.getBool(storageKey) ?? false;
    } catch (_) {
      // Off is always a usable answer.
    }
  }

  Future<void> select(bool enabled) async {
    state = enabled;
    final prefs = await ref.read(preferencesProvider.future);
    await prefs.setBool(storageKey, enabled);
  }
}
