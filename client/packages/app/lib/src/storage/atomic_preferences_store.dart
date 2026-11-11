// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The preferences file on Linux and Windows, written so a kill cannot erase it.
///
/// The stock plugin rewrites the whole file in place and keeps a per-process
/// cache of it. A kill mid-write leaves it empty or truncated, which reads
/// back as every setting gone; a second or older process rewrites its stale
/// cache over newer values. This store keeps the same file name and JSON
/// format, so an existing file carries over untouched.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

const _defaultPrefix = 'flutter.';

/// How a read of the preferences file went.
enum PreferencesReadOutcome { restoredFromBackup, unrecoverable }

typedef PreferencesReadReport = void Function(PreferencesReadOutcome outcome);

/// A [SharedPreferencesStorePlatform] over one atomically replaced JSON file.
///
/// A write reloads the file and changes only its own key, so a stale process
/// never reverts another's setting; the one remaining window is two processes
/// writing within the same few milliseconds.
class AtomicPreferencesStore extends SharedPreferencesStorePlatform {
  AtomicPreferencesStore({
    Future<Directory> Function()? directory,
    this.fileName = 'shared_preferences',
    PreferencesReadReport? onRead,
  }) : _directory = directory ?? getApplicationSupportDirectory,
       _onRead = onRead ?? _logRead;

  final Future<Directory> Function() _directory;
  final String fileName;
  final PreferencesReadReport _onRead;
  Future<void> _queue = Future.value();

  Future<File> _file(String suffix) async {
    final dir = await _directory();
    return File(p.join(dir.path, '$fileName.json$suffix'));
  }

  @override
  Future<Map<String, Object>> getAll() => getAllWithParameters(
    GetAllParameters(filter: PreferencesFilter(prefix: _defaultPrefix)),
  );

  @override
  Future<Map<String, Object>> getAllWithPrefix(String prefix) =>
      getAllWithParameters(
        GetAllParameters(filter: PreferencesFilter(prefix: prefix)),
      );

  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) async {
    final filter = parameters.filter;
    final all = await _read();
    return {
      for (final entry in all.entries)
        if (entry.key.startsWith(filter.prefix) &&
            (filter.allowList?.contains(entry.key) ?? true))
          entry.key: entry.value,
    };
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) =>
      _change((all) => all[key] = value);

  @override
  Future<bool> remove(String key) => _change((all) => all.remove(key));

  @override
  Future<bool> clear() => clearWithParameters(
    ClearParameters(filter: PreferencesFilter(prefix: _defaultPrefix)),
  );

  @override
  Future<bool> clearWithPrefix(String prefix) => clearWithParameters(
    ClearParameters(filter: PreferencesFilter(prefix: prefix)),
  );

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) {
    final filter = parameters.filter;
    return _change(
      (all) => all.removeWhere(
        (key, _) =>
            key.startsWith(filter.prefix) &&
            (filter.allowList?.contains(key) ?? true),
      ),
    );
  }

  Future<bool> _change(void Function(Map<String, Object> all) edit) {
    final done = _queue.then((_) async {
      try {
        final all = await _read();
        edit(all);
        await _write(all);
        return true;
      } on Object catch (error, stack) {
        AppLog.warning(
          LogTag.data,
          'Could not save preferences',
          error: error,
          stack: stack,
        );
        return false;
      }
    });
    _queue = done.then((_) {});
    return done;
  }

  Future<Map<String, Object>> _read() async {
    final main = await _decode(await _file(''));
    if (main != null) return main;
    final backup = await _decode(await _file('.bak'));
    final mainExists = await (await _file('')).exists();
    if (backup != null) {
      _onRead(PreferencesReadOutcome.restoredFromBackup);
      return backup;
    }
    if (mainExists) _onRead(PreferencesReadOutcome.unrecoverable);
    return {};
  }

  /// The file's map, or null when it is missing, empty or does not parse.
  Future<Map<String, Object>?> _decode(File file) async {
    try {
      final text = await file.readAsString();
      if (text.isEmpty) return null;
      final data = json.decode(text);
      if (data is! Map) return null;
      return data.cast<String, Object>();
    } on Object catch (error, stack) {
      AppLog.swallowed(
        LogTag.data,
        'A settings file could not be read; its backup is tried next',
        error,
        stack,
      );
      return null;
    }
  }

  Future<void> _write(Map<String, Object> all) async {
    final file = await _file('');
    await file.parent.create(recursive: true);
    if (await _decode(file) != null) {
      await _replace(await _file('.bak'), await file.readAsBytes());
    }
    await _replace(file, utf8.encode(json.encode(all)));
  }

  Future<void> _replace(File target, List<int> bytes) async {
    final temp = File('${target.path}.tmp.$pid');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(target.path);
  }

  static void _logRead(PreferencesReadOutcome outcome) {
    final what = outcome == PreferencesReadOutcome.restoredFromBackup
        ? 'Preferences file was unreadable; restored the previous copy'
        : 'Preferences file was unreadable and no backup could be used; settings reset';
    AppLog.warning(LogTag.data, what);
  }
}
