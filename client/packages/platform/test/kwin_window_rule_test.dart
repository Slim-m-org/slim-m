// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The pop-out's window rule is written once, checked for failure, and taken back out.
@TestOn('vm')
library;

import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/src/kwin_window_rule.dart';

class _KwinBus extends DBusClient {
  _KwinBus({this.running = true})
      : super(DBusAddress.unix(path: '/nonexistent'));

  final bool running;
  int reconfigures = 0;

  @override
  Future<DBusMethodSuccessResponse> callMethod({
    String? destination,
    required DBusObjectPath path,
    String? interface,
    required String name,
    Iterable<DBusValue> values = const [],
    DBusSignature? replySignature,
    bool noReplyExpected = false,
    bool noAutoStart = false,
    bool allowInteractiveAuthorization = false,
  }) async {
    if (name == 'NameHasOwner') {
      return DBusMethodSuccessResponse([DBusBoolean(running)]);
    }
    if (name == 'reconfigure') reconfigures++;
    return DBusMethodSuccessResponse();
  }

  @override
  Future<void> close() async {}
}

/// `kreadconfig6` and `kwriteconfig6` over an in-memory `kwinrulesrc`.
class _FakeConfig {
  final groups = <String, Map<String, String>>{};
  final commands = <String>[];
  bool failWrites = false;

  int get writes => commands.where((c) => c.startsWith('kwriteconfig6')).length;

  Future<ProcessResult> run(String command, List<String> args) async {
    commands.add('$command ${args.join(' ')}');
    final group = args[3];
    final key = args[5];
    if (command == 'kreadconfig6') {
      return ProcessResult(1, 0, '${groups[group]?[key] ?? ''}\n', '');
    }
    if (failWrites) {
      return ProcessResult(1, 1, '', 'kwriteconfig6: cannot write');
    }
    if (args.length > 6 && args[6] == '--delete') {
      groups[group]?.remove(key);
      if (groups[group]?.isEmpty ?? false) groups.remove(group);
    } else {
      (groups[group] ??= {})[key] = args[6];
    }
    return ProcessResult(1, 0, '', '');
  }
}

void main() {
  late _KwinBus bus;
  late _FakeConfig config;

  setUp(() {
    bus = _KwinBus();
    config = _FakeConfig();
  });

  Future<bool> add() =>
      kwinAboveFullScreen('slim-m pop-out', client: bus, run: config.run);
  Future<bool> remove() =>
      kwinRemoveAboveFullScreen(client: bus, run: config.run);

  test('the rule is written and KWin reloaded, once per pop-out', () async {
    expect(await add(), isTrue);
    expect(config.groups[kwinAboveFullScreenRule], {
      'Description': 'slim-m pop-out',
      'title': 'slim-m pop-out',
      'titlematch': '1',
      'layer': 'popup',
      'layerrule': '2',
    });
    expect(config.groups['General']!['rules'], kwinAboveFullScreenRule);
    expect(config.groups['General']!['count'], '1');
    expect(bus.reconfigures, 1);

    final writes = config.writes;
    expect(await add(), isTrue);
    expect(config.writes, writes, reason: 'a rule already in place');
    expect(bus.reconfigures, 1);
  });

  test('a config that lists its rules under Order keeps that list', () async {
    config.groups['General'] = {'Order': 'other'};
    await add();
    expect(
        config.groups['General']!['Order'], 'other,$kwinAboveFullScreenRule');
    expect(config.groups['General']!.containsKey('rules'), isFalse);
  });

  test('closing takes the rule out of the list and drops its group', () async {
    config.groups['General'] = {'rules': 'other', 'count': '1'};
    await add();
    expect(await remove(), isTrue);
    expect(config.groups.containsKey(kwinAboveFullScreenRule), isFalse);
    expect(config.groups['General'], {'rules': 'other', 'count': '1'});
    expect(bus.reconfigures, 2);
  });

  test('closing with no rule in place changes nothing', () async {
    config.groups['General'] = {'rules': 'other'};
    expect(await remove(), isTrue);
    expect(config.writes, 0);
    expect(bus.reconfigures, 0);
  });

  test('a pop-out after a close writes the rule again', () async {
    await add();
    await remove();
    await add();
    expect(config.groups.containsKey(kwinAboveFullScreenRule), isTrue);
    expect(bus.reconfigures, 3);
  });

  test('where KWin is not running the config is never touched', () async {
    bus = _KwinBus(running: false);
    expect(await add(), isFalse);
    expect(await remove(), isFalse);
    expect(config.commands, isEmpty);
  });

  test('a write that fails is not reported as done', () async {
    config.failWrites = true;
    expect(await add(), isFalse);
    expect(bus.reconfigures, 0);
  });

  test('a rule taken out of a list leaves the others alone', () {
    expect(withoutRule('a,r,b', 'r'), 'a,b');
    expect(withoutRule('r', 'r'), '');
    expect(withoutRule('a, b', 'r'), 'a,b');
  });

  final tools = ['kwriteconfig6', 'kreadconfig6'].every(
    (tool) => Process.runSync('which', [tool]).exitCode == 0,
  );

  group('against the real KDE config tools', () {
    late Directory home;

    setUp(() => home = Directory.systemTemp.createTempSync('slimm-kwinrules-'));
    tearDown(() => home.deleteSync(recursive: true));

    Future<ProcessResult> real(String command, List<String> args) =>
        Process.run(command, args, environment: {'XDG_CONFIG_HOME': home.path});

    test('the rule comes and goes from a real kwinrulesrc', () async {
      await kwinAboveFullScreen('slim-m pop-out', client: bus, run: real);
      final file = File('${home.path}/kwinrulesrc');
      expect(file.readAsStringSync(), contains('[$kwinAboveFullScreenRule]'));
      expect(file.readAsStringSync(), contains('layer=popup'));

      await kwinAboveFullScreen('slim-m pop-out', client: bus, run: real);
      expect(bus.reconfigures, 1, reason: 'already in place');

      await kwinRemoveAboveFullScreen(client: bus, run: real);
      expect(file.readAsStringSync(), isNot(contains(kwinAboveFullScreenRule)));
      expect(bus.reconfigures, 2);
    },
        skip:
            tools ? false : 'kwriteconfig6 and kreadconfig6 are not installed');
  });
}
