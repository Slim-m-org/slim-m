// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:dbus/dbus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/src/global_hotkeys_channel.dart';
import 'package:slimm_platform/src/global_hotkeys_portal.dart';

class _RecordingBus extends DBusClient {
  _RecordingBus() : super(DBusAddress.unix(path: '/nonexistent'));
  final calls = <String>[];
  var closed = false;

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
    calls.add('${path.value} $interface.$name');
    return DBusMethodSuccessResponse();
  }

  @override
  Future<void> close() async => closed = true;
}

const _ptt = GlobalHotkeyBinding(
  id: GlobalHotkeyId.pushToTalk,
  description: 'Push to talk',
  chord: HotkeyChord(LogicalKeyboardKey.f13),
);
const _mute = GlobalHotkeyBinding(
  id: GlobalHotkeyId.toggleMute,
  description: 'Mute or unmute',
  chord: HotkeyChord(LogicalKeyboardKey.keyM, ctrl: true, shift: true),
);

DBusSignal _signal(String name, String session, String id) => DBusSignal(
      sender: ':1.5',
      path: DBusObjectPath(portalSessionPathForTest),
      interface: 'org.freedesktop.portal.GlobalShortcuts',
      name: name,
      values: [
        DBusObjectPath(session),
        DBusString(id),
        const DBusUint64(7),
        DBusDict.stringVariant({})
      ],
    );

const portalSessionPathForTest = '/org/freedesktop/portal/desktop';
const _session = '/org/freedesktop/portal/desktop/session/1_42/slimm_session_0';

void main() {
  test('the session handle is read out of a Response dictionary', () {
    final results = DBusDict.stringVariant({
      'session_handle': const DBusString(_session),
    }).asStringVariantDict();
    expect(portalSessionHandle(results), _session);
    expect(portalSessionHandle({}), isNull);
    expect(portalSessionHandle(null), isNull);
  });

  test('the request path follows the unique name and token', () {
    expect(
      portalRequestPath(':1.42', 'tok'),
      '/org/freedesktop/portal/desktop/request/1_42/tok',
    );
  });

  test('CreateSession carries both tokens', () {
    final values = createSessionValues(handleToken: 'h', sessionToken: 's');
    expect(values.single.signature.value, 'a{sv}');
    final dict = values.single.asStringVariantDict();
    expect(dict['handle_token']!.asString(), 'h');
    expect(dict['session_handle_token']!.asString(), 's');
  });

  test('BindShortcuts lists each shortcut with its description and trigger',
      () {
    final values = bindShortcutsValues(
      sessionHandle: _session,
      bindings: [_ptt, _mute],
      handleToken: 'h',
    );
    expect(values.map((v) => v.signature.value).join(), 'oa(sa{sv})sa{sv}');
    final entries = values[1].asArray().toList();
    expect(entries, hasLength(2));
    final first = entries[0].asStruct();
    expect(first[0].asString(), 'pushToTalk');
    final firstProps = first[1].asStringVariantDict();
    expect(firstProps['description']!.asString(), 'Push to talk');
    expect(firstProps['preferred_trigger']!.asString(), 'F13');
    final second = entries[1].asStruct()[1].asStringVariantDict();
    expect(second['preferred_trigger']!.asString(), 'CTRL+SHIFT+m');
  });

  test('a bare letter is never suggested as a trigger', () {
    expect(
        portalTriggerFor(const HotkeyChord(LogicalKeyboardKey.keyV)), isNull);
    final values = bindShortcutsValues(
      sessionHandle: _session,
      bindings: const [
        GlobalHotkeyBinding(
          id: GlobalHotkeyId.pushToTalk,
          description: 'Push to talk',
          chord: HotkeyChord(LogicalKeyboardKey.keyV),
        ),
      ],
      handleToken: 'h',
    );
    final props =
        values[1].asArray().single.asStruct()[1].asStringVariantDict();
    expect(props.containsKey('preferred_trigger'), isFalse);
  });

  test('Activated and Deactivated become a press and a release', () {
    final down = portalEventFromSignal(
      _signal('Activated', _session, 'pushToTalk'),
      _session,
    );
    final up = portalEventFromSignal(
      _signal('Deactivated', _session, 'pushToTalk'),
      _session,
    );
    expect(down!.id, GlobalHotkeyId.pushToTalk);
    expect(down.phase, GlobalHotkeyPhase.pressed);
    expect(up!.phase, GlobalHotkeyPhase.released);
  });

  test('signals for another session or an unknown shortcut are ignored', () {
    expect(
      portalEventFromSignal(
          _signal('Activated', '/other', 'pushToTalk'), _session),
      isNull,
    );
    expect(
      portalEventFromSignal(_signal('Activated', _session, 'nope'), _session),
      isNull,
    );
    expect(
      portalEventFromSignal(
          _signal('ShortcutsChanged', _session, 'x'), _session),
      isNull,
    );
  });

  test('Windows codes cover letters, function keys and numpad', () {
    expect(windowsVirtualKeyFor(LogicalKeyboardKey.keyV), 0x56);
    expect(windowsVirtualKeyFor(LogicalKeyboardKey.digit5), 0x35);
    expect(windowsVirtualKeyFor(LogicalKeyboardKey.f13), 0x7C);
    expect(windowsVirtualKeyFor(LogicalKeyboardKey.numpad5), 0x65);
    expect(windowsVirtualKeyFor(LogicalKeyboardKey.controlRight), 0xA3);
    expect(windowsVirtualKeyFor(LogicalKeyboardKey.audioVolumeUp), isNull);
  });

  test('the hook binding payload holds the code and modifiers', () {
    final payload = hookBindingsFor([_mute])!.single;
    expect(payload['id'], 'toggleMute');
    expect(payload['vk'], 0x4D);
    expect(payload['ctrl'], true);
    expect(payload['alt'], false);
    expect(
        hookBindingsFor([
          const GlobalHotkeyBinding(
            id: GlobalHotkeyId.pushToTalk,
            description: 'x',
            chord: HotkeyChord(LogicalKeyboardKey.audioVolumeUp),
          ),
        ]),
        isNull);
  });

  test('native calls become events', () {
    final press = hookEventFromCall(
      const MethodCall('event', {'id': 'pushToTalk', 'pressed': true}),
    );
    expect(press!.phase, GlobalHotkeyPhase.pressed);
    expect(
      hookEventFromCall(const MethodCall('lost'))!.phase,
      GlobalHotkeyPhase.lost,
    );
    expect(hookEventFromCall(const MethodCall('event', {'id': 'x'})), isNull);
  });

  test('unbinding everything closes the portal session', () async {
    final bus = _RecordingBus();
    final source = PortalGlobalHotkeySource(clientFactory: () => bus)
      ..adoptSessionForTest(_session);
    await source.bind(const []);
    expect(bus.calls, ['$_session org.freedesktop.portal.Session.Close']);
    await source.bind(const []);
    expect(bus.calls, hasLength(1));
    await source.dispose();
  });

  test('dispose closes a live session', () async {
    final bus = _RecordingBus();
    final source = PortalGlobalHotkeySource(clientFactory: () => bus)
      ..adoptSessionForTest(_session);
    await source.dispose();
    expect(bus.calls, ['$_session org.freedesktop.portal.Session.Close']);
  });
}
