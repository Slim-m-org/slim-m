// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The KWin window rule that lifts the pop-out above full screen windows.
///
/// It lives in the user's `kwinrulesrc` only while a pop-out is open: it is
/// written once per pop-out, left alone when it is already right, and removed
/// when the window closes. Nothing is touched where KWin is not running.
library;

import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

const _service = 'org.kde.KWin';
const _rulesFile = 'kwinrulesrc';

/// The `kwinrulesrc` group holding the rule.
const kwinAboveFullScreenRule = 'slimm-above-fullscreen';

/// Runs a command; tests stand in for `kreadconfig6` and `kwriteconfig6`.
typedef ConfigRunner = Future<ProcessResult> Function(
  String command,
  List<String> arguments,
);

/// [list], a comma-separated rule list from `kwinrulesrc`, with [id] added once.
String withRule(String list, String id) {
  final ids = _ids(list);
  return ids.contains(id) ? ids.join(',') : [...ids, id].join(',');
}

/// [list] without [id].
String withoutRule(String list, String id) =>
    _ids(list).where((part) => part != id).join(',');

List<String> _ids(String list) => [
      for (final part in list.split(','))
        if (part.trim().isNotEmpty) part.trim(),
    ];

Map<String, String> _ruleKeys(String caption) => {
      'Description': caption,
      'title': caption,
      'titlematch': '1',
      'layer': 'popup',
      'layerrule': '2',
    };

class _RulesFile {
  _RulesFile(this._run);

  final ConfigRunner _run;

  Future<String> read(String group, String key) async {
    final arguments = _target(group, key);
    final result = await _run('kreadconfig6', arguments);
    _expectSuccess('kreadconfig6', arguments, result);
    return (result.stdout as String).trim();
  }

  Future<void> write(String group, String key, String value) =>
      _change([..._target(group, key), value]);

  Future<void> delete(String group, String key) =>
      _change([..._target(group, key), '--delete']);

  Future<void> _change(List<String> arguments) async {
    final result = await _run('kwriteconfig6', arguments);
    _expectSuccess('kwriteconfig6', arguments, result);
  }

  List<String> _target(String group, String key) =>
      ['--file', _rulesFile, '--group', group, '--key', key];

  void _expectSuccess(
    String command,
    List<String> arguments,
    ProcessResult result,
  ) {
    if (result.exitCode == 0) return;
    throw ProcessException(
        command, arguments, '${result.stderr}', result.exitCode);
  }

  /// Lists the rule and writes its keys, each only where it differs; true when anything changed.
  Future<bool> ensure(String caption) async {
    var changed = await _ensureListed();
    for (final MapEntry(:key, :value) in _ruleKeys(caption).entries) {
      if (await read(kwinAboveFullScreenRule, key) == value) continue;
      await write(kwinAboveFullScreenRule, key, value);
      changed = true;
    }
    return changed;
  }

  /// Unlists the rule and drops its keys, which removes the group; true when anything changed.
  Future<bool> remove() async {
    var changed = false;
    for (final key in const ['Order', 'rules']) {
      changed |= await _unlist(key);
    }
    for (final key in _ruleKeys('').keys) {
      if ((await read(kwinAboveFullScreenRule, key)).isEmpty) continue;
      await delete(kwinAboveFullScreenRule, key);
      changed = true;
    }
    return changed;
  }

  // KWin has listed its rules under `rules` and later `Order`; add to whichever this config uses.
  Future<bool> _ensureListed() async {
    final order = await read('General', 'Order');
    final key = order.isNotEmpty ? 'Order' : 'rules';
    final current = order.isNotEmpty ? order : await read('General', 'rules');
    if (_ids(current).contains(kwinAboveFullScreenRule)) return false;
    await _writeList(key, withRule(current, kwinAboveFullScreenRule));
    return true;
  }

  Future<bool> _unlist(String key) async {
    final current = await read('General', key);
    if (!_ids(current).contains(kwinAboveFullScreenRule)) return false;
    await _writeList(key, withoutRule(current, kwinAboveFullScreenRule));
    return true;
  }

  Future<void> _writeList(String key, String list) async {
    await write('General', key, list);
    if (key == 'rules') await write('General', 'count', '${_ids(list).length}');
  }
}

Future<void> _queue = Future<void>.value();

// A pop-out opening while the last one is still being cleaned up must not interleave its reads and writes.
Future<bool> _serially(Future<bool> Function() run) {
  final result = _queue.then((_) => run());
  _queue = result.then<void>((_) {});
  return result;
}

/// Puts a rule in the user's KWin config that keeps windows titled [caption]
/// above full screen ones, and has KWin reload its rules only when it changed;
/// false where KWin or its config tools are absent.
Future<bool> kwinAboveFullScreen(
  String caption, {
  DBusClient? client,
  ConfigRunner run = Process.run,
}) =>
    _serially(
      () => _withRules(client, run, (rules) => rules.ensure(caption)),
    );

/// Takes the rule [kwinAboveFullScreen] added back out of the user's KWin config.
Future<bool> kwinRemoveAboveFullScreen({
  DBusClient? client,
  ConfigRunner run = Process.run,
}) =>
    _serially(() => _withRules(client, run, (rules) => rules.remove()));

Future<bool> _withRules(
  DBusClient? client,
  ConfigRunner run,
  Future<bool> Function(_RulesFile rules) change,
) async {
  final bus = client ?? DBusClient.session();
  try {
    if (!await bus.nameHasOwner(_service)) return false;
    if (await change(_RulesFile(run))) await _reconfigure(bus);
    return true;
  } on Object catch (error, stack) {
    AppLog.swallowed(LogTag.platform, 'Could not change the KWin pop-out rule',
        error, stack);
    return false;
  } finally {
    if (client == null) await bus.close();
  }
}

Future<void> _reconfigure(DBusClient bus) => bus.callMethod(
      destination: _service,
      path: DBusObjectPath('/KWin'),
      interface: 'org.kde.KWin',
      name: 'reconfigure',
      replySignature: DBusSignature(''),
    );
