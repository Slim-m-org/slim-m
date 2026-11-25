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
  final _pending = <_PendingChange>[];

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
    final change = _PendingChange(edit);
    _pending.add(change);
    _queue = _queue.then((_) => _flush());
    return change.done.future;
  }

  /// Applies every change queued so far with one read and one write.
  Future<void> _flush() async {
    if (_pending.isEmpty) return;
    final batch = List.of(_pending);
    _pending.clear();
    try {
      final snapshot = await _load();
      for (final change in batch) {
        change.edit(snapshot.all);
      }
      await _write(snapshot);
      for (final change in batch) {
        change.done.complete(true);
      }
    } on Object catch (error, stack) {
      AppLog.warning(
        LogTag.data,
        'Could not save preferences',
        error: error,
        stack: stack,
      );
      for (final change in batch) {
        change.done.complete(false);
      }
    }
  }

  Future<Map<String, Object>> _read() async => (await _load()).all;

  Future<_Snapshot> _load() async {
    final main = await _decode(await _file(''));
    if (main.all != null) return _Snapshot(main.all!, main.bytes);
    final backup = await _decode(await _file('.bak'));
    if (backup.all != null) {
      _onRead(PreferencesReadOutcome.restoredFromBackup);
      return _Snapshot(backup.all!, null);
    }
    if (main.exists) _onRead(PreferencesReadOutcome.unrecoverable);
    return _Snapshot({}, null);
  }

  /// A missing, empty, unparsable or non-map file reads as corrupt; any other
  /// failure to read it propagates so a transient I/O error never costs settings.
  Future<_Decoded> _decode(File file) async {
    final List<int> bytes;
    try {
      bytes = await file.readAsBytes();
    } on PathNotFoundException {
      return const _Decoded(null, null, exists: false);
    }
    try {
      final data = bytes.isEmpty ? null : json.decode(utf8.decode(bytes));
      if (data is Map) {
        return _Decoded(data.cast<String, Object>(), bytes, exists: true);
      }
    } on FormatException catch (error, stack) {
      AppLog.swallowed(
        LogTag.data,
        'A settings file could not be parsed; its backup is tried next',
        error,
        stack,
      );
    }
    return const _Decoded(null, null, exists: true);
  }

  Future<void> _write(_Snapshot snapshot) async {
    final file = await _file('');
    await file.parent.create(recursive: true);
    final previous = snapshot.mainBytes;
    if (previous != null) await _replace(await _file('.bak'), previous);
    await _replace(file, utf8.encode(json.encode(snapshot.all)));
  }

  Future<void> _replace(File target, List<int> bytes) async {
    final temp = File('${target.path}.tmp.$pid');
    try {
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(target.path);
    } on Object {
      await temp.delete().catchError((Object _) => temp);
      rethrow;
    }
  }

  static void _logRead(PreferencesReadOutcome outcome) {
    final what = outcome == PreferencesReadOutcome.restoredFromBackup
        ? 'Preferences file was unreadable; restored the previous copy'
        : 'Preferences file was unreadable and no backup could be used; settings reset';
    AppLog.warning(LogTag.data, what);
  }
}

class _PendingChange {
  _PendingChange(this.edit);

  final void Function(Map<String, Object> all) edit;
  final done = Completer<bool>();
}

class _Snapshot {
  _Snapshot(this.all, this.mainBytes);

  final Map<String, Object> all;

  /// The main file as read, kept as the next backup; null when it was not good.
  final List<int>? mainBytes;
}

class _Decoded {
  const _Decoded(this.all, this.bytes, {required this.exists});

  final Map<String, Object>? all;
  final List<int>? bytes;
  final bool exists;
}
