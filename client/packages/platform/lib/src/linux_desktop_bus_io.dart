// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two session-bus signals a Linux desktop gives a chat app: the launcher
/// unread count, and the activation token that lets a banner click raise the
/// window on Wayland, which refuses focus without one.
library;

import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

import 'local_notifications.dart' show linuxDesktopEntry;

const _launcherPath = '/com/canonical/unity/launcherentry/1';
const _launcherInterface = 'com.canonical.Unity.LauncherEntry';
const _notificationsName = 'org.freedesktop.Notifications';

/// How long a token stays good: a click's token arrives just before its action.
const activationTokenLifetime = Duration(seconds: 10);

/// The Unity LauncherEntry count, which KDE and the GNOME dock show on the launcher icon.
class LinuxLauncherCount {
  LinuxLauncherCount({Future<void> Function(int count)? emit})
      : _emit = emit ?? _emitOnSessionBus;

  final Future<void> Function(int count) _emit;
  int? _last;

  Future<void> set(int count) async {
    final shown = count < 0 ? 0 : count;
    if (shown == _last) return;
    _last = shown;
    try {
      await _emit(shown);
    } on Object catch (error, stack) {
      AppLog.swallowed(
          LogTag.platform, 'Could not set the launcher count', error, stack);
    }
  }

  static DBusClient? _bus;

  static Future<void> _emitOnSessionBus(int count) {
    final bus = _bus ??= DBusClient.session();
    return bus.emitSignal(
      path: DBusObjectPath(_launcherPath),
      interface: _launcherInterface,
      name: 'Update',
      values: [
        const DBusString('application://$linuxDesktopEntry.desktop'),
        DBusDict.stringVariant({
          'count': DBusInt64(count),
          'count-visible': DBusBoolean(count > 0),
        }),
      ],
    );
  }
}

/// Remembers the newest activation token the notification server sent.
class LinuxActivationToken {
  LinuxActivationToken({Stream<String>? tokens, DateTime Function()? clock})
      : _tokens = tokens,
        _clock = clock ?? DateTime.now;

  final Stream<String>? _tokens;
  final DateTime Function() _clock;
  StreamSubscription<String>? _subscription;
  String? _token;
  DateTime? _at;

  /// Starts listening; calling it again does nothing.
  void listen() {
    if (_subscription != null) return;
    final source = _tokens ?? _serverTokens();
    _subscription = source.listen((token) {
      _token = token;
      _at = _clock();
    }, onError: (Object error, StackTrace stack) {
      AppLog.swallowed(
          LogTag.platform, 'Could not read an activation token', error, stack);
    });
  }

  /// The token for the click being handled, once; null when none is fresh.
  String? take() {
    final token = _token;
    final at = _at;
    _token = null;
    _at = null;
    if (token == null || token.isEmpty || at == null) return null;
    return _clock().difference(at) <= activationTokenLifetime ? token : null;
  }

  static Stream<String> _serverTokens() {
    final bus = DBusClient.session();
    final signals = DBusRemoteObjectSignalStream(
      object: DBusRemoteObject(
        bus,
        name: _notificationsName,
        path: DBusObjectPath('/org/freedesktop/Notifications'),
      ),
      interface: _notificationsName,
      name: 'ActivationToken',
    );
    return signals
        .where((signal) => signal.signature == DBusSignature('us'))
        .map((signal) => (signal.values[1] as DBusString).value);
  }
}
