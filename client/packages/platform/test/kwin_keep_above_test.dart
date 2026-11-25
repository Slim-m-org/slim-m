// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/src/kwin_keep_above.dart';

/// A KWin scripting service that logs each call and can refuse to run a script.
class _ScriptingBus extends DBusClient {
  _ScriptingBus({this.runs = true, this.hangs = false})
      : super(DBusAddress.unix(path: '/nonexistent'));

  final bool runs;
  final bool hangs;
  final calls = <String>[];
  var _nextId = 0;

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
    if (hangs) await Completer<void>().future;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final plugin = values.isEmpty ? '' : (values.last as DBusString).value;
    calls.add('$name $plugin'.trim());
    if (name == 'loadScript') {
      return DBusMethodSuccessResponse([DBusInt32(_nextId++)]);
    }
    if (name == 'run' && !runs) {
      throw DBusMethodResponseException(
          DBusMethodErrorResponse.unknownObject());
    }
    return DBusMethodSuccessResponse(
      name == 'unloadScript' ? [const DBusBoolean(true)] : [],
    );
  }

  @override
  Future<void> close() async {}
}

void main() {
  test('the script names this process and the exact title', () {
    final script = keepAboveScript(pid: 4242, caption: 'slim-m pop-out');
    expect(script, contains('w.pid === 4242'));
    expect(script, contains("w.caption === 'slim-m pop-out'"));
    expect(script, contains('w.keepAbove = true'));
  });

  test('a quote in the title cannot end the script string', () {
    final script = keepAboveScript(pid: 1, caption: "it's \\ here");
    expect(script, contains(r"w.caption === 'it\'s \\ here'"));
  });

  test('works on Plasma 5 as well as 6', () {
    expect(keepAboveScript(pid: 1, caption: 'x'),
        contains('workspace.clientList()'));
  });

  test('the full screen rule joins an existing rule list once', () {
    expect(withRule('', 'r'), 'r');
    expect(withRule('a,b', 'r'), 'a,b,r');
    expect(withRule('a, r ,b', 'r'), 'a,r,b');
  });

  group('against KWin', () {
    test('a KWin that never answers does not block the next pop-out', () async {
      final hung = _ScriptingBus(hangs: true);
      final ok = _ScriptingBus();
      final first = kwinKeepAbove('first',
          client: hung, timeout: const Duration(milliseconds: 20));
      final second = kwinKeepAbove('second', client: ok);
      expect(await first, isFalse);
      expect(await second, isTrue);
    });

    test('two pop-outs opened together load and unload one after the other',
        () async {
      final bus = _ScriptingBus();
      final both = await Future.wait([
        kwinKeepAbove('first', client: bus),
        kwinKeepAbove('second', client: bus),
      ]);
      expect(both, [true, true]);
      final steps = [for (final c in bus.calls) c.split(' ').first];
      const oneCall = ['unloadScript', 'loadScript', 'run', 'unloadScript'];
      expect(steps, [...oneCall, ...oneCall]);
    });

    test('each call unloads only the script it loaded', () async {
      final bus = _ScriptingBus();
      await kwinKeepAbove('first', client: bus);
      await kwinKeepAbove('second', client: bus);
      final names = {
        for (final c in bus.calls)
          if (c.startsWith('unloadScript ')) c,
      };
      expect(names, hasLength(2));
    });

    test('a script KWin never ran is not reported as done', () async {
      final bus = _ScriptingBus(runs: false);
      expect(await kwinKeepAbove('x', client: bus), isFalse);
      expect(bus.calls.last, startsWith('unloadScript'));
    });
  });
}
