// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Linux system idle time: the runner's Wayland ext-idle-notify-v1 channel
/// first, then D-Bus (freedesktop ScreenSaver, GNOME's IdleMonitor) and the
/// screen lock as a last resort.
///
/// [SystemIdle.idleTime] is synchronous, so a poll keeps a cached sample that is
/// aged by the clock between polls. KDE Wayland answers no D-Bus idle call, and
/// the runner channel only reports idle past its notification timeout.
library;

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:dbus/dbus.dart';
import 'package:flutter/services.dart';

import 'system_idle.dart';

const _pollInterval = Duration(seconds: 10);

/// One idle reading from the session, or null when this source cannot say.
typedef IdleProbe = Future<Duration?> Function();

/// Sources in preference order; the first one that answers wins.
/// Each poll asks from the top again, since a source that failed once can come up later.
class LinuxSystemIdle implements SystemIdle {
  LinuxSystemIdle({
    required List<IdleProbe> probes,
    Duration pollInterval = _pollInterval,
  }) : _probes = probes {
    _poll();
    _timer = Timer.periodic(pollInterval, (_) => _poll());
  }

  final List<IdleProbe> _probes;
  late final Timer _timer;
  Duration? _sample;
  DateTime? _sampledAt;
  bool _polling = false;

  @override
  Duration? idleTime() {
    final sample = _sample;
    final at = _sampledAt;
    if (sample == null || at == null) return null;
    return sample + clock.now().difference(at);
  }

  void dispose() => _timer.cancel();

  Future<void> _poll() async {
    if (_polling) return;
    _polling = true;
    try {
      Duration? idle;
      for (final probe in _probes) {
        idle = await _safely(probe);
        if (idle != null) break;
      }
      _sample = idle;
      _sampledAt = clock.now();
    } finally {
      _polling = false;
    }
  }

  Future<Duration?> _safely(IdleProbe probe) async {
    try {
      return await probe();
    } on Object {
      return null;
    }
  }
}

/// The default chain against the user's session bus.
SystemIdle? createLinuxSystemIdle() {
  final client = DBusClient.session();
  final locked = _LockedSince();
  return LinuxSystemIdle(
    probes: [
      _runnerIdle,
      () => _screenSaverIdle(client),
      () => _mutterIdle(client),
      () => locked.probe(client),
    ],
  );
}

const _runnerChannel = MethodChannel('top.npcserver.slimm/linux_idle');

/// Null where the runner has no Wayland idle notifier (X11, other compositors, or a build without it).
Future<Duration?> _runnerIdle() async {
  final ms = await _runnerChannel.invokeMethod<int>('idleMs');
  return ms == null ? null : Duration(milliseconds: ms);
}

Future<Duration?> _screenSaverIdle(DBusClient client) async {
  final reply = await client.callMethod(
    destination: 'org.freedesktop.ScreenSaver',
    path: DBusObjectPath('/org/freedesktop/ScreenSaver'),
    interface: 'org.freedesktop.ScreenSaver',
    name: 'GetSessionIdleTime',
    replySignature: DBusSignature('u'),
  );
  return Duration(milliseconds: reply.returnValues.first.asUint32());
}

Future<Duration?> _mutterIdle(DBusClient client) async {
  final reply = await client.callMethod(
    destination: 'org.gnome.Mutter.IdleMonitor',
    path: DBusObjectPath('/org/gnome/Mutter/IdleMonitor/Core'),
    interface: 'org.gnome.Mutter.IdleMonitor',
    name: 'GetIdletime',
    replySignature: DBusSignature('t'),
  );
  return Duration(milliseconds: reply.returnValues.first.asUint64());
}

/// A locked screen is a person who is away, measured from when we first saw it.
class _LockedSince {
  DateTime? _since;

  Future<Duration?> probe(DBusClient client) async {
    final reply = await client.callMethod(
      destination: 'org.freedesktop.ScreenSaver',
      path: DBusObjectPath('/org/freedesktop/ScreenSaver'),
      interface: 'org.freedesktop.ScreenSaver',
      name: 'GetActive',
      replySignature: DBusSignature('b'),
    );
    if (!reply.returnValues.first.asBoolean()) {
      _since = null;
      return null;
    }
    return clock.now().difference(_since ??= clock.now());
  }
}
