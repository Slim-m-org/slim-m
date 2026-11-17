// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The portal hotkey source against a real D-Bus connection and a stand-in
/// portal that answers every request at once, the way KDE's does.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:dbus/dbus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/src/global_hotkeys_portal.dart';

class _Portal extends DBusObject {
  _Portal() : super(DBusObjectPath('/org/freedesktop/portal/desktop'));

  final methods = <String>[];
  final registered = <String>{};
  final bound = <List<String>>[];
  var sessions = 0;
  String? lastSession;

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async =>
      DBusGetPropertyResponse(const DBusUint32(1));

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    methods.add(call.name);
    final sender = call.sender!;
    if (call.interface == 'org.freedesktop.host.portal.Registry') {
      registered.add(sender);
      return DBusMethodSuccessResponse();
    }
    if (!registered.contains(sender)) {
      return DBusMethodErrorResponse(
        'org.freedesktop.portal.Error.NotAllowed',
        [const DBusString('An app id is required')],
      );
    }
    final options = call.values.last.asStringVariantDict();
    final token = options['handle_token']!.asString();
    final request = portalRequestPath(sender, token);
    final results = <String, DBusValue>{};
    if (call.name == 'CreateSession') {
      final session = _Session(
        '/org/freedesktop/portal/desktop/session/'
        '${sender.substring(1).replaceAll('.', '_')}/s${sessions++}',
        methods,
      );
      await client!.registerObject(session);
      lastSession = session.path.value;
      results['session_handle'] = DBusString(session.path.value);
    }
    if (call.name == 'BindShortcuts') {
      bound.add([
        for (final entry in call.values[1].asArray())
          (entry as DBusStruct).children.first.asString(),
      ]);
    }
    unawaited(
      client!.emitSignal(
        path: DBusObjectPath(request),
        interface: 'org.freedesktop.portal.Request',
        name: 'Response',
        values: [const DBusUint32(0), DBusDict.stringVariant(results)],
      ),
    );
    return DBusMethodSuccessResponse([DBusObjectPath(request)]);
  }
}

class _Session extends DBusObject {
  _Session(String path, this.methods) : super(DBusObjectPath(path));

  final List<String> methods;

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    methods.add(call.name);
    if (call.name == 'Close') await client!.unregisterObject(this);
    return DBusMethodSuccessResponse();
  }
}

/// Hosts the bus and the portal in their own isolate, so the test can stall
/// its own isolate while the portal keeps answering.
Future<void> _hostPortal(SendPort reply) async {
  final dir = Directory.systemTemp.createTempSync('slimm-portal-bus-');
  final server = DBusServer();
  final address = await server.listenAddress(DBusAddress.unix(dir: dir));
  final bus = DBusClient(address);
  await bus.requestName('org.freedesktop.portal.Desktop');
  final portal = _Portal();
  await bus.registerObject(portal);
  final commands = ReceivePort();
  reply.send((address.value, commands.sendPort));
  await for (final command in commands) {
    if (command case ('press', final String id)) {
      await bus.emitSignal(
        path: DBusObjectPath('/org/freedesktop/portal/desktop'),
        interface: 'org.freedesktop.portal.GlobalShortcuts',
        name: 'Activated',
        values: [
          DBusObjectPath(portal.lastSession!),
          DBusString(id),
          const DBusUint64(0),
          DBusDict.stringVariant({}),
        ],
      );
      continue;
    }
    reply.send((portal.methods, portal.bound));
    await bus.close();
    await server.close();
    dir.deleteSync(recursive: true);
    commands.close();
  }
}

/// Stalls right after sending CreateSession, the way a call joining keeps the
/// app busy, so the portal's replies queue up and are read in one batch.
class _BusyClient extends DBusClient {
  _BusyClient(super.address);

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
  }) {
    final result = super.callMethod(
      destination: destination,
      path: path,
      interface: interface,
      name: name,
      values: values,
      replySignature: replySignature,
    );
    if (name == 'CreateSession') {
      Timer.run(() => sleep(const Duration(milliseconds: 300)));
    }
    return result;
  }
}

typedef _Seen = (List<String> methods, List<List<String>> bound);

/// A source wired to a stand-in portal, a stop that returns what the portal
/// saw, and a press of one shortcut in the portal's latest session.
Future<
    (
      PortalGlobalHotkeySource,
      Future<_Seen> Function(),
      void Function(GlobalHotkeyId),
    )> _withPortal({
  DBusClient Function(DBusAddress address) client = DBusClient.new,
}) async {
  final replies = ReceivePort();
  final isolate = await Isolate.spawn(_hostPortal, replies.sendPort);
  final inbox = StreamIterator(replies);
  await inbox.moveNext();
  final (address, commands) = inbox.current as (String, SendPort);
  final source = PortalGlobalHotkeySource(
    clientFactory: () => client(DBusAddress(address)),
    approvalTimeout: const Duration(seconds: 2),
  );
  Future<_Seen> stop() async {
    await source.dispose();
    commands.send('stop');
    await inbox.moveNext();
    replies.close();
    isolate.kill();
    return inbox.current as _Seen;
  }

  void press(GlobalHotkeyId id) => commands.send(('press', id.name));

  return (source, stop, press);
}

GlobalHotkeyBinding _binding(GlobalHotkeyId id, LogicalKeyboardKey key) =>
    GlobalHotkeyBinding(
      id: id,
      description: id.name,
      chord: HotkeyChord(key, ctrl: true, shift: true),
    );

final _mute = _binding(GlobalHotkeyId.toggleMute, LogicalKeyboardKey.keyM);
final _deafen = _binding(GlobalHotkeyId.toggleDeafen, LogicalKeyboardKey.keyD);
final _talk = _binding(GlobalHotkeyId.pushToTalk, LogicalKeyboardKey.keyV);

void main() {
  test('an answer read in the same batch as the name lookup is not lost',
      () async {
    final (source, stop, _) = await _withPortal(client: _BusyClient.new);
    final result = await source.bind([_mute]);
    final (methods, _) = await stop();
    expect(methods, ['Register', 'CreateSession', 'BindShortcuts', 'Close']);
    expect(result.available, isTrue);
  });

  test('a changed set of shortcuts is bound in a fresh session', () async {
    final (source, stop, _) = await _withPortal();
    await source.bind([_talk]);
    await source.bind([_talk, _mute, _deafen]);
    await source.bind([_talk, _mute, _deafen]);
    await source.bind([_talk]);
    final (methods, bound) = await stop();
    expect(methods, [
      'Register',
      'CreateSession',
      'BindShortcuts',
      'Close',
      'CreateSession',
      'BindShortcuts',
      'BindShortcuts',
      'Close',
      'CreateSession',
      'BindShortcuts',
      'Close',
    ]);
    expect(bound.last, ['pushToTalk']);
  });

  test('a rebind while a shortcut is held releases it', () async {
    final (source, stop, press) = await _withPortal();
    final events = <GlobalHotkeyEvent>[];
    final subscription = source.events.listen(events.add);
    await source.bind([_talk]);
    press(GlobalHotkeyId.pushToTalk);
    for (var i = 0; i < 100 && events.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(events.map((e) => e.phase), [GlobalHotkeyPhase.pressed]);

    await source.bind([_talk, _mute]);
    await Future<void>.delayed(Duration.zero);
    await subscription.cancel();
    await stop();
    expect(
      events.map((e) => (e.id, e.phase)),
      [
        (GlobalHotkeyId.pushToTalk, GlobalHotkeyPhase.pressed),
        (GlobalHotkeyId.pushToTalk, GlobalHotkeyPhase.released),
      ],
    );
  });
}
