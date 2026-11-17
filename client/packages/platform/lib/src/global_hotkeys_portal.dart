// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Linux global hotkeys over the desktop portal's GlobalShortcuts interface.
///
/// The portal, not this app, owns which key triggers a shortcut: the person
/// approves or changes it in the desktop's own dialog and settings, and the
/// portal grabs it exclusively. Activated and Deactivated give the press and
/// the release push-to-talk needs.
library;

import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart' show setEquals, visibleForTesting;

import 'global_hotkeys.dart';
import 'global_hotkeys_keys.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag, reportFailure;
import 'portal_request.dart';

export 'portal_request.dart' show portalRequestPath;

const _shortcutsInterface = 'org.freedesktop.portal.GlobalShortcuts';
const _registryInterface = 'org.freedesktop.host.portal.Registry';
const _sessionInterface = 'org.freedesktop.portal.Session';

/// The id the desktop entry and the GTK window carry.
const linuxAppId = 'top.npcserver.slimm';

const portalAvailableMessage =
    'Works when slim-m is in the background. Pick the key in System Settings, Shortcuts.';
const portalMissingMessage =
    'This desktop has no background shortcuts, so it works only while slim-m is focused.';
const portalDeclinedMessage =
    'Background shortcuts were not approved, so this works only while slim-m is focused.';

List<DBusValue> createSessionValues({
  required String handleToken,
  required String sessionToken,
}) =>
    [
      DBusDict.stringVariant({
        'handle_token': DBusString(handleToken),
        'session_handle_token': DBusString(sessionToken),
      }),
    ];

List<DBusValue> bindShortcutsValues({
  required String sessionHandle,
  required List<GlobalHotkeyBinding> bindings,
  required String handleToken,
}) =>
    [
      DBusObjectPath(sessionHandle),
      DBusArray(DBusSignature('(sa{sv})'), [
        for (final binding in bindings) _shortcutEntry(binding),
      ]),
      const DBusString(''),
      DBusDict.stringVariant({'handle_token': DBusString(handleToken)}),
    ];

DBusStruct _shortcutEntry(GlobalHotkeyBinding binding) {
  final trigger = portalTriggerFor(binding.chord);
  return DBusStruct([
    DBusString(binding.id.name),
    DBusDict.stringVariant({
      'description': DBusString(binding.description),
      if (trigger != null) 'preferred_trigger': DBusString(trigger),
    }),
  ]);
}

/// The session path in a CreateSession response, or null when it has none.
String? portalSessionHandle(Map<String, DBusValue>? results) {
  final handle = results?['session_handle'];
  return handle is DBusString ? handle.asString() : null;
}

/// The press or release a portal signal reports for [sessionHandle], or null.
GlobalHotkeyEvent? portalEventFromSignal(
  DBusSignal signal,
  String sessionHandle,
) {
  final phase = switch (signal.name) {
    'Activated' => GlobalHotkeyPhase.pressed,
    'Deactivated' => GlobalHotkeyPhase.released,
    _ => null,
  };
  if (phase == null || signal.values.length < 2) return null;
  if (signal.values[0].asObjectPath().value != sessionHandle) return null;
  final id = signal.values[1].asString();
  for (final known in GlobalHotkeyId.values) {
    if (known.name == id) return GlobalHotkeyEvent(known, phase);
  }
  return null;
}

class PortalGlobalHotkeySource implements GlobalHotkeySource {
  /// [responses] and [approvalTimeout] let a test stand in for the portal's answers.
  PortalGlobalHotkeySource({
    DBusClient Function()? clientFactory,
    Stream<DBusSignal> Function(DBusClient bus, DBusObjectPath request)?
        responses,
    Duration approvalTimeout = portalApprovalTimeout,
    String appId = linuxAppId,
  })  : _clientFactory = clientFactory ?? DBusClient.session,
        _appId = appId,
        _responses = responses,
        _approvalTimeout = approvalTimeout;

  final DBusClient Function() _clientFactory;
  final Stream<DBusSignal> Function(DBusClient bus, DBusObjectPath request)?
      _responses;
  final Duration _approvalTimeout;
  final String _appId;
  final _events = StreamController<GlobalHotkeyEvent>.broadcast();
  final _listening = <StreamSubscription<DBusSignal>>[];
  DBusClient? _client;
  Future<void>? _registration;
  String? _owner;
  String? _session;
  Set<GlobalHotkeyId> _boundIds = const {};
  final _held = <GlobalHotkeyId>{};
  int _tokenCounter = 0;

  @override
  Stream<GlobalHotkeyEvent> get events => _events.stream;

  DBusClient get _bus => _client ??= _clientFactory();

  String _token(String kind) => 'slimm_${kind}_${_tokenCounter++}';

  @override
  Future<GlobalHotkeyAvailability> probe() async {
    try {
      final version = await DBusRemoteObject(
        _bus,
        name: portalBusName,
        path: DBusObjectPath(portalPath),
      ).getProperty(_shortcutsInterface, 'version');
      return version.asUint32() >= 1
          ? const GlobalHotkeyAvailability.available(portalAvailableMessage)
          : const GlobalHotkeyAvailability.unavailable(portalMissingMessage);
    } on Object catch (error, stack) {
      AppLog.swallowed(LogTag.platform,
          'Could not reach the global shortcuts portal', error, stack);
      return const GlobalHotkeyAvailability.unavailable(portalMissingMessage);
    }
  }

  @override
  Future<GlobalHotkeyAvailability> bind(
    List<GlobalHotkeyBinding> bindings,
  ) async {
    if (bindings.isEmpty) {
      await _closeSession();
      return const GlobalHotkeyAvailability.available(portalAvailableMessage);
    }
    final ids = {for (final binding in bindings) binding.id};
    // KDE keeps an id a rebind leaves out and asks again for one it adds, but binds a fresh session silently.
    if (!setEquals(ids, _boundIds)) await _closeSession();
    try {
      final session = _session ?? await _createSession();
      final results = await _request(
        'BindShortcuts',
        (token) => bindShortcutsValues(
          sessionHandle: session,
          bindings: bindings,
          handleToken: token,
        ),
      );
      if (results == null) {
        return const GlobalHotkeyAvailability.unavailable(
          portalDeclinedMessage,
        );
      }
      _boundIds = ids;
      return const GlobalHotkeyAvailability.available(portalAvailableMessage);
    } on Object catch (error, stack) {
      reportFailure(LogTag.platform, 'bind the global shortcuts', error, stack);
      _endSession();
      return const GlobalHotkeyAvailability.unavailable(portalMissingMessage);
    }
  }

  @visibleForTesting
  // ignore: use_setters_to_change_properties
  void adoptSessionForTest(String handle) => _session = handle;

  /// Releases the portal's grab on every approved key; the next bind re-creates.
  Future<void> _closeSession() async {
    final handle = _session;
    if (handle == null) return;
    for (final subscription in _listening) {
      unawaited(subscription.cancel());
    }
    _listening.clear();
    _session = null;
    _boundIds = const {};
    // The closed session never delivers these key-ups, so a held push to talk would stay open.
    for (final id in _held) {
      if (!_events.isClosed) {
        _events.add(GlobalHotkeyEvent(id, GlobalHotkeyPhase.released));
      }
    }
    _held.clear();
    try {
      await _bus.callMethod(
        destination: portalBusName,
        path: DBusObjectPath(handle),
        interface: _sessionInterface,
        name: 'Close',
        replySignature: DBusSignature(''),
      );
    } on Object catch (error, stack) {
      AppLog.swallowed(
        LogTag.platform,
        'The global shortcuts portal session was already closed',
        error,
        stack,
      );
    }
  }

  /// The portal refuses a host app's session without an id, and GTK's own
  /// registration covers only GTK's connection, not this one.
  Future<void> _registerApp() => _registration ??= _register();

  Future<void> _register() async {
    try {
      await _bus.callMethod(
        destination: portalBusName,
        path: DBusObjectPath(portalPath),
        interface: _registryInterface,
        name: 'Register',
        values: [DBusString(_appId), DBusDict.stringVariant({})],
        replySignature: DBusSignature(''),
      );
    } on Object catch (error, stack) {
      AppLog.swallowed(LogTag.platform,
          'The portal kept the app id it already had', error, stack);
    }
  }

  Future<String> _portalOwner() async => _owner ??= await portalOwner(_bus);

  Future<String> _createSession() async {
    await _registerApp();
    _owner = null;
    final results = await _request(
      'CreateSession',
      (token) => createSessionValues(
        handleToken: token,
        sessionToken: _token('session'),
      ),
    );
    final handle = portalSessionHandle(results);
    if (handle == null) throw StateError('portal returned no session');
    _session = handle;
    _watchSession(handle);
    return handle;
  }

  void _watchSession(String handle) {
    final sender = _owner ?? portalBusName;
    for (final name in const ['Activated', 'Deactivated']) {
      _listening.add(
        DBusSignalStream(
          _bus,
          sender: sender,
          interface: _shortcutsInterface,
          name: name,
        ).listen((signal) {
          final event = portalEventFromSignal(signal, handle);
          if (event == null) return;
          if (event.phase == GlobalHotkeyPhase.pressed) _held.add(event.id!);
          if (event.phase == GlobalHotkeyPhase.released) _held.remove(event.id);
          _events.add(event);
        }),
      );
    }
    _listening.add(
      DBusSignalStream(
        _bus,
        sender: sender,
        interface: _sessionInterface,
        name: 'Closed',
        path: DBusObjectPath(handle),
      ).listen((_) => _endSession()),
    );
  }

  void _endSession() {
    for (final subscription in _listening) {
      unawaited(subscription.cancel());
    }
    _listening.clear();
    _boundIds = const {};
    _held.clear();
    if (_session == null) return;
    _session = null;
    if (!_events.isClosed) _events.add(const GlobalHotkeyEvent.lost());
  }

  /// Runs a portal method and waits for its Response. Null results mean the person declined.
  Future<Map<String, DBusValue>?> _request(
    String method,
    List<DBusValue> Function(String token) values,
  ) async {
    final token = _token('request');
    final path = DBusObjectPath(portalRequestPath(_bus.uniqueName, token));
    final responses = _responses?.call(_bus, path) ??
        portalResponses(_bus, path, sender: await _portalOwner());
    final response = await awaitPortalResponse(
      responses: responses,
      call: () => _bus.callMethod(
        destination: portalBusName,
        path: DBusObjectPath(portalPath),
        interface: _shortcutsInterface,
        name: method,
        values: values(token),
        replySignature: DBusSignature('o'),
      ),
      timeout: _approvalTimeout,
    );
    return response.code == 0 ? response.results : null;
  }

  @override
  Future<void> dispose() async {
    await _closeSession();
    _endSession();
    await _events.close();
    await _client?.close();
    _client = null;
    _registration = null;
    _owner = null;
  }
}
