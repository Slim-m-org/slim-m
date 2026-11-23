// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call shortcuts a person remapped, kept on this device.
///
/// Off on a desktop until the person turns them on. An absent entry means the
/// default; the effective map is mirrored into [userShortcutOverrides].
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show SingleActivator, ShortcutActivator;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:slimm_platform/platform.dart';

import '../../../providers/providers.dart';

/// The actions whose shortcut the person can change.
const remappableActions = [
  AppAction.toggleMuteCall,
  AppAction.toggleDeafenCall,
  AppAction.toggleCameraCall,
  AppAction.toggleShareCall,
  AppAction.markCallMoment,
  AppAction.leaveCall,
  AppAction.toggleCallOverlay,
];

/// Hold-to-talk key until the person picks another.
const kDefaultPushToTalkKey = LogicalKeyboardKey.keyV;

const _storeKey = 'slimm.voice.shortcut_overrides';
const _enabledKey = 'slimm.voice.call_keybinds_enabled';

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

/// Null for an action means the person cleared its shortcut.
String encodeOverrides(Map<AppAction, SingleActivator?> overrides) =>
    jsonEncode({
      for (final e in overrides.entries)
        e.key.name: switch (e.value) {
          null => null,
          final chord => {
            'key': chord.trigger.keyId,
            'ctrl': chord.control,
            'alt': chord.alt,
            'shift': chord.shift,
            'meta': chord.meta,
          },
        },
    });

/// The stored overrides; anything unreadable or no longer remappable is dropped.
Map<AppAction, SingleActivator?> decodeOverrides(String? stored) {
  if (stored == null) return const {};
  try {
    final json = jsonDecode(stored);
    if (json is! Map) return const {};
    final out = <AppAction, SingleActivator?>{};
    for (final action in remappableActions) {
      if (!json.containsKey(action.name)) continue;
      final entry = json[action.name];
      if (entry == null) {
        out[action] = null;
        continue;
      }
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

/// Whether the call keybinds are on, and how the person changed them.
class CallKeybinds {
  const CallKeybinds({
    this.enabled = false,
    this.overrides = const {},
    this.optIn = true,
  });

  /// Off means no call shortcut is bound, in the window or system-wide.
  final bool enabled;
  final Map<AppAction, SingleActivator?> overrides;

  /// False where no shortcut is grabbed system-wide, so the switch does not apply.
  final bool optIn;

  /// What every hint and binding reads: all call actions unbound while off.
  Map<AppAction, SingleActivator?> get effective => enabled || !optIn
      ? overrides
      : {for (final action in remappableActions) action: null};

  CallKeybinds copyWith({
    bool? enabled,
    Map<AppAction, SingleActivator?>? overrides,
  }) => CallKeybinds(
    enabled: enabled ?? this.enabled,
    overrides: overrides ?? this.overrides,
    optIn: optIn,
  );
}

/// Only a desktop build grabs keys system-wide, so only there are call keybinds opt-in.
final callKeybindsOptInProvider = Provider<bool>((ref) => isDesktopHost);

/// This device's call keybinds, one instance for every signed-in server.
class CallKeybindsStore extends ChangeNotifier {
  CallKeybindsStore({bool optIn = true}) : _value = CallKeybinds(optIn: optIn) {
    _mirror();
  }

  CallKeybinds _value;
  bool _disposed = false;
  Future<void>? _loaded;

  CallKeybinds get value => _value;

  /// Reads what is stored once, however many servers ask.
  Future<void> load(Future<SharedPreferences> prefs) =>
      _loaded ??= _load(prefs);

  Future<void> _load(Future<SharedPreferences> pending) async {
    final prefs = await pending;
    if (_disposed) return;
    final stored = prefs.getString(_storeKey);
    final enabled = prefs.getBool(_enabledKey);
    // Someone who already remapped a shortcut asked for keybinds, so they stay on.
    final migrated = enabled ?? stored != null;
    if (enabled == null) await prefs.setBool(_enabledKey, migrated);
    _publish(
      _value.copyWith(enabled: migrated, overrides: decodeOverrides(stored)),
    );
  }

  Future<void> setEnabled(bool on, Future<SharedPreferences> prefs) async {
    _publish(_value.copyWith(enabled: on));
    await (await prefs).setBool(_enabledKey, on);
  }

  Future<void> setOverrides(
    Map<AppAction, SingleActivator?> next,
    Future<SharedPreferences> pending,
  ) async {
    _publish(_value.copyWith(overrides: next));
    final prefs = await pending;
    if (next.isEmpty) {
      await prefs.remove(_storeKey);
    } else {
      await prefs.setString(_storeKey, encodeOverrides(next));
    }
  }

  void _publish(CallKeybinds next) {
    if (_disposed) return;
    _value = next;
    _mirror();
    notifyListeners();
  }

  void _mirror() => userShortcutOverrides = Map.unmodifiable(_value.effective);

  @override
  void dispose() {
    _disposed = true;
    userShortcutOverrides = const {};
    super.dispose();
  }
}

/// Overridden with one shared store in every account's container.
final callKeybindsStoreProvider = Provider<CallKeybindsStore>((ref) {
  final store = CallKeybindsStore(optIn: ref.watch(callKeybindsOptInProvider));
  ref.onDispose(store.dispose);
  return store;
});

/// One server's view of [CallKeybindsStore]; every change lands in the shared store.
class ShortcutOverridesController extends StateNotifier<CallKeybinds> {
  ShortcutOverridesController(this._ref)
    : _store = _ref.read(callKeybindsStoreProvider),
      super(_ref.read(callKeybindsStoreProvider).value) {
    _store.addListener(_follow);
    _ready = _store.load(_prefs());
  }

  final Ref _ref;
  final CallKeybindsStore _store;
  late final Future<void> _ready;

  void _follow() => state = _store.value;

  Future<SharedPreferences> _prefs() => _ref.read(preferencesProvider.future);

  Future<void> setEnabled(bool on) async {
    await _ready;
    if (!mounted) return;
    await _store.setEnabled(on, _prefs());
  }

  Future<void> set(AppAction action, SingleActivator chord) =>
      _edit((overrides) => {...overrides, action: chord});

  /// Leaves [action] with no shortcut at all.
  Future<void> clear(AppAction action) =>
      _edit((overrides) => {...overrides, action: null});

  /// Back to the default chord for every action.
  Future<void> reset() => _edit((_) => const {});

  Future<void> _edit(
    Map<AppAction, SingleActivator?> Function(Map<AppAction, SingleActivator?>)
    change,
  ) async {
    await _ready;
    if (!mounted) return;
    await _store.setOverrides(change(_store.value.overrides), _prefs());
  }

  @override
  void dispose() {
    _store.removeListener(_follow);
    super.dispose();
  }
}

final shortcutOverridesProvider =
    StateNotifierProvider<ShortcutOverridesController, CallKeybinds>(
      ShortcutOverridesController.new,
    );
