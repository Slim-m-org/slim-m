// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The mute and deafen shortcuts a person remapped, kept on this device.
///
/// An absent entry means the default. The map is mirrored into
/// [userShortcutOverrides] so every hint and binding follows the change.
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show SingleActivator, ShortcutActivator;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:slimm_platform/platform.dart';

import '../../../providers/providers.dart';

/// The actions whose shortcut the person can change.
const remappableActions = [
  AppAction.toggleMuteCall,
  AppAction.toggleDeafenCall,
];

/// Hold-to-talk key until the person picks another.
const kDefaultPushToTalkKey = LogicalKeyboardKey.keyV;

const _storeKey = 'slimm.voice.shortcut_overrides';

/// Whether [a] and [b] fire on exactly the same chord.
bool sameChord(SingleActivator a, SingleActivator b) =>
    a.trigger == b.trigger &&
    a.control == b.control &&
    a.alt == b.alt &&
    a.shift == b.shift &&
    a.meta == b.meta;

/// `Ctrl+Shift+M`, the way a key cap or a message names [activator].
String chordLabel(SingleActivator activator) => [
  if (activator.meta) 'Cmd',
  if (activator.control) 'Ctrl',
  if (activator.alt) 'Alt',
  if (activator.shift) 'Shift',
  _triggerLabel(activator.trigger),
].join('+');

String _triggerLabel(LogicalKeyboardKey key) {
  final label = key.keyLabel.trim();
  if (label.isNotEmpty) return label.length == 1 ? label.toUpperCase() : label;
  return key.debugName ?? 'Key ${key.keyId}';
}

final _modifierKeys = {
  LogicalKeyboardKey.controlLeft,
  LogicalKeyboardKey.controlRight,
  LogicalKeyboardKey.shiftLeft,
  LogicalKeyboardKey.shiftRight,
  LogicalKeyboardKey.altLeft,
  LogicalKeyboardKey.altRight,
  LogicalKeyboardKey.metaLeft,
  LogicalKeyboardKey.metaRight,
};

bool _isModifierKey(LogicalKeyboardKey key) => _modifierKeys.contains(key);

bool _isFunctionKey(LogicalKeyboardKey key) =>
    RegExp(r'^F([1-9]|1[0-9]|2[0-4])$').hasMatch(key.keyLabel);

/// Why [chord] cannot be a call shortcut, or null when it can.
///
/// A bare letter would be swallowed while typing, so a modifier or a function
/// key is required.
String? shortcutRuleViolation(SingleActivator chord) {
  if (_isModifierKey(chord.trigger)) return null;
  final hasModifier = chord.control || chord.alt || chord.meta;
  if (hasModifier || _isFunctionKey(chord.trigger)) return null;
  return 'Hold Ctrl, Alt or Cmd with the key, or use an F key.';
}

/// Whether the captured key is only a modifier going down, so capture keeps waiting.
bool isModifierOnly(LogicalKeyboardKey key) => _isModifierKey(key);

String _actionName(AppAction action) =>
    action.label.replaceAll(' (in a call)', '');

/// What [chord] already does, or null when it is free for [action].
///
/// Checks the other shortcuts as the person has them now, the server switcher
/// and the push-to-talk key.
String? shortcutConflict({
  required SingleActivator chord,
  required AppAction? action,
  required LogicalKeyboardKey pushToTalkKey,
  Map<AppAction, ShortcutActivator?>? overrides,
}) {
  for (final entry in resolveBindings(overrides: overrides).entries) {
    final other = entry.key;
    if (entry.value == action || other is! SingleActivator) continue;
    if (sameChord(other, chord)) return _actionName(entry.value);
  }
  for (final other in serverSwitchActivators()) {
    if (sameChord(other, chord)) return 'Switch server';
  }
  final bare = !chord.control && !chord.alt && !chord.shift && !chord.meta;
  if (bare && chord.trigger == pushToTalkKey && action != null) {
    return 'Push to talk';
  }
  return null;
}

/// What a push-to-talk [key] already does, or null when it is free.
String? pushToTalkConflict(
  LogicalKeyboardKey key, {
  Map<AppAction, ShortcutActivator?>? overrides,
}) => shortcutConflict(
  chord: SingleActivator(key),
  action: null,
  pushToTalkKey: key,
  overrides: overrides,
);

String encodeOverrides(Map<AppAction, SingleActivator> overrides) =>
    jsonEncode({
      for (final e in overrides.entries)
        e.key.name: {
          'key': e.value.trigger.keyId,
          'ctrl': e.value.control,
          'alt': e.value.alt,
          'shift': e.value.shift,
          'meta': e.value.meta,
        },
    });

/// The stored overrides; anything unreadable or no longer remappable is dropped.
Map<AppAction, SingleActivator> decodeOverrides(String? stored) {
  if (stored == null) return const {};
  try {
    final json = jsonDecode(stored);
    if (json is! Map) return const {};
    final out = <AppAction, SingleActivator>{};
    for (final action in remappableActions) {
      final entry = json[action.name];
      if (entry is! Map || entry['key'] is! int) continue;
      out[action] = SingleActivator(
        LogicalKeyboardKey(entry['key'] as int),
        control: entry['ctrl'] == true,
        alt: entry['alt'] == true,
        shift: entry['shift'] == true,
        meta: entry['meta'] == true,
      );
    }
    return out;
  } on FormatException catch (error, stack) {
    AppLog.swallowed(
      LogTag.ui,
      'Stored shortcuts were unreadable; using the defaults',
      error,
      stack,
    );
    return const {};
  }
}

class ShortcutOverridesController
    extends StateNotifier<Map<AppAction, SingleActivator>> {
  ShortcutOverridesController(this._ref) : super(const {}) {
    _ready = _load();
  }

  final Ref _ref;
  late final Future<void> _ready;

  Future<void> _load() async {
    final prefs = await _ref.read(preferencesProvider.future);
    if (!mounted) return;
    _apply(decodeOverrides(prefs.getString(_storeKey)));
  }

  void _apply(Map<AppAction, SingleActivator> next) {
    userShortcutOverrides = Map.unmodifiable(next);
    state = next;
  }

  Future<void> set(AppAction action, SingleActivator chord) =>
      _ready.then((_) => _save({...state, action: chord}));

  /// Back to the default chord for every action.
  Future<void> reset() => _save(const {});

  Future<void> _save(Map<AppAction, SingleActivator> next) async {
    await _ready;
    if (!mounted) return;
    _apply(next);
    final prefs = await _ref.read(preferencesProvider.future);
    if (next.isEmpty) {
      await prefs.remove(_storeKey);
    } else {
      await prefs.setString(_storeKey, encodeOverrides(next));
    }
  }

  @override
  void dispose() {
    userShortcutOverrides = const {};
    super.dispose();
  }
}

final shortcutOverridesProvider =
    StateNotifierProvider<
      ShortcutOverridesController,
      Map<AppAction, SingleActivator>
    >(ShortcutOverridesController.new);
