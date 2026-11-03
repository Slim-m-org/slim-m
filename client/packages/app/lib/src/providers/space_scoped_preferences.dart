// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Preferences that belong to one Space rather than to the device.
/// See docs/decisions/0070-space-scoped-settings.md for the classification.
library;

import 'package:shared_preferences/shared_preferences.dart';

/// Every key whose value is kept per Space. A key not listed here is device-wide.
const Set<String> spaceScopedKeys = {
  'slimm.appearance.theme',
  'slimm.appearance.time_format',
  'slimm.appearance.message_density',
  'slimm.appearance.group_spacing',
  'slimm.appearance.continuation_marker',
  'slimm.notifications.ui_sounds_enabled',
  'slimm.notifications.haptics_enabled',
  'slimm.notifications.message_sounds_enabled',
  'slimm.notifications.desktop_message_text',
  'slimm.modules.sound_enabled',
  'slimm.performance.media_autodownload',
  'slimm.performance.gif_autoplay',
  'slimm.performance.link_previews',
  'slimm.composer.reply_mention',
  'slimm.presence.share_listening',
  'slimm.presence.share_game',
  'slimm.presence.share_spotify',
  'slimm.voice.join_leave_sounds_enabled',
  'slimm.voice.hold_music_enabled',
  'slimm.voice.hold_music_track',
  'slimm.voice.hold_music_volume',
  'slimm.voice.call_ring_sound_enabled',
};

/// Where [key] is stored for the Space at [origin].
String spaceScopedKey(String origin, String key) => 'slimm.space.$origin.$key';

/// Reads and writes [spaceScopedKeys] under the current Space's own key.
///
/// A Space that has not stored a value yet reads the device-level one, which is
/// how values saved before preferences were per Space carry over to every Space.
class SpaceScopedPreferences implements SharedPreferences {
  SpaceScopedPreferences(this._base, this._origin);

  final SharedPreferences _base;

  /// Resolved on every call: an account is filed after its container exists.
  final String? Function() _origin;

  String? _scopedKey(String key) {
    final origin = _origin();
    if (origin == null || !spaceScopedKeys.contains(key)) return null;
    return spaceScopedKey(origin, key);
  }

  T? _read<T>(String key, T? Function(String key) get) {
    final scoped = _scopedKey(key);
    if (scoped == null) return get(key);
    return _base.containsKey(scoped) ? get(scoped) : get(key);
  }

  Future<bool> _write(String key, Future<bool> Function(String key) set) =>
      set(_scopedKey(key) ?? key);

  @override
  Set<String> getKeys() => _base.getKeys();

  @override
  Object? get(String key) => _read(key, _base.get);

  @override
  bool? getBool(String key) => _read(key, _base.getBool);

  @override
  int? getInt(String key) => _read(key, _base.getInt);

  @override
  double? getDouble(String key) => _read(key, _base.getDouble);

  @override
  String? getString(String key) => _read(key, _base.getString);

  @override
  List<String>? getStringList(String key) => _read(key, _base.getStringList);

  @override
  bool containsKey(String key) {
    final scoped = _scopedKey(key);
    return (scoped != null && _base.containsKey(scoped)) ||
        _base.containsKey(key);
  }

  @override
  Future<bool> setBool(String key, bool value) =>
      _write(key, (k) => _base.setBool(k, value));

  @override
  Future<bool> setInt(String key, int value) =>
      _write(key, (k) => _base.setInt(k, value));

  @override
  Future<bool> setDouble(String key, double value) =>
      _write(key, (k) => _base.setDouble(k, value));

  @override
  Future<bool> setString(String key, String value) =>
      _write(key, (k) => _base.setString(k, value));

  @override
  Future<bool> setStringList(String key, List<String> value) =>
      _write(key, (k) => _base.setStringList(k, value));

  @override
  Future<bool> remove(String key) => _base.remove(_scopedKey(key) ?? key);

  // ignore: deprecated_member_use
  @override
  Future<bool> commit() async => true;

  @override
  Future<bool> clear() => _base.clear();

  @override
  Future<void> reload() => _base.reload();
}
