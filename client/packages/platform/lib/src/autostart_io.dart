// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The desktop login launches: an XDG autostart entry on Linux, the Background
/// portal under Flatpak (which cannot write the host's autostart directory),
/// the per-user Run key on Windows, and a login item on macOS 13 or newer.
library;

import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/services.dart';

import 'autostart.dart';
import 'autostart_target.dart';
import 'install_format.dart';
import 'portal_request.dart';

const _appName = 'slim-m';

/// The app id every Linux package installs its desktop entry and icon under.
const linuxAppId = 'top.npcserver.slimm';

Future<Autostart?> hostAutostart() async {
  if (Platform.isLinux) {
    final env = Platform.environment;
    if (currentInstallFormat() == InstallFormat.flatpak) {
      return FlatpakAutostart(marker: XdgAutostart.entryFor(env));
    }
    return XdgAutostart(
      entry: XdgAutostart.entryFor(env),
      executable: linuxAutostartExecutable(Platform.resolvedExecutable),
    );
  }
  if (Platform.isWindows) {
    return WindowsRunKeyAutostart(
      executable: windowsAutostartExecutable(Platform.resolvedExecutable),
    );
  }
  if (Platform.isMacOS) {
    final login = MacLoginItemAutostart();
    return await login.isSupported() ? login : null;
  }
  return null;
}

/// An XDG autostart entry, `~/.config/autostart/top.npcserver.slimm.desktop`.
class XdgAutostart implements Autostart {
  XdgAutostart({required this.entry, required this.executable});

  final File entry;
  final String executable;

  /// Honours XDG_CONFIG_HOME, as the session's autostart reader does.
  static File entryFor(Map<String, String> env) {
    final config = env['XDG_CONFIG_HOME'] ?? '${env['HOME'] ?? ''}/.config';
    return File('$config/autostart/$linuxAppId.desktop');
  }

  /// The entry's contents; the executable is quoted, as the desktop entry spec asks for a path with spaces.
  static String desktopEntry(String executable) {
    final quoted =
        '"${executable.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
    return '[Desktop Entry]\n'
        'Type=Application\n'
        'Name=slim-m\n'
        'Exec=$quoted $autostartArgument\n'
        'Icon=$linuxAppId\n'
        'X-GNOME-Autostart-enabled=true\n';
  }

  @override
  Future<bool> isEnabled() async {
    if (!entry.existsSync()) return false;
    final text = await entry.readAsString();
    return !text.contains('Hidden=true') &&
        !text.contains('X-GNOME-Autostart-enabled=false');
  }

  @override
  Future<void> setEnabled(bool on) async {
    if (!on) {
      if (entry.existsSync()) await entry.delete();
      return;
    }
    await entry.parent.create(recursive: true);
    await entry.writeAsString(desktopEntry(executable));
  }

  @override
  Future<void> repair() async {
    if (!await isEnabled()) return;
    if (await entry.readAsString() != desktopEntry(executable)) {
      await setEnabled(true);
    }
  }
}

/// The Background portal registers the login launch on the host; it cannot be
/// read back from inside the sandbox, so an entry in the sandbox's own config
/// directory records the last answer.
class FlatpakAutostart implements Autostart {
  /// [request] lets a test stand in for the portal.
  FlatpakAutostart({
    required this.marker,
    Future<PortalResponse> Function(bool autostart)? request,
  }) : _request = request ?? _requestBackground;

  final File marker;
  final Future<PortalResponse> Function(bool autostart) _request;

  @override
  Future<bool> isEnabled() async => marker.existsSync();

  // The portal registers the host's own command line, which already names `slim-m` on the PATH.
  @override
  Future<void> repair() async {}

  @override
  Future<void> setEnabled(bool on) async {
    final response = await _request(on);
    if (response.code != 0) throw AutostartDeniedException(response.code);
    final registered = response.results['autostart'];
    final autostarts = registered is DBusBoolean ? registered.value : on;
    if (autostarts) {
      await marker.parent.create(recursive: true);
      await marker.writeAsString(XdgAutostart.desktopEntry(_appName));
    } else if (marker.existsSync()) {
      await marker.delete();
    }
    if (on && !autostarts) throw AutostartDeniedException(response.code);
  }
}

/// The portal answered a login launch request with a no, or with a registration other than the one asked for.
class AutostartDeniedException implements Exception {
  const AutostartDeniedException(this.responseCode);

  /// The portal's response code; 0 means it answered but did not register the launch.
  final int responseCode;

  @override
  String toString() => 'The portal did not register the login launch '
      '(response $responseCode)';
}

Future<PortalResponse> _requestBackground(bool autostart) async {
  const token = 'slimm_autostart';
  final client = DBusClient.session();
  try {
    await client.ping();
    final path = DBusObjectPath(portalRequestPath(client.uniqueName, token));
    return await awaitPortalResponse(
      responses: portalResponses(client, path),
      call: () => client.callMethod(
        destination: portalBusName,
        path: DBusObjectPath(portalPath),
        interface: 'org.freedesktop.portal.Background',
        name: 'RequestBackground',
        values: [
          const DBusString(''),
          DBusDict.stringVariant({
            'handle_token': const DBusString(token),
            'reason': const DBusString('Start slim-m when you sign in'),
            'autostart': DBusBoolean(autostart),
            'commandline': DBusArray.string([_appName, autostartArgument]),
          }),
        ],
      ),
    );
  } finally {
    await client.close();
  }
}

/// The per-user Run key, written through `reg.exe` so no Win32 bindings are needed.
class WindowsRunKeyAutostart implements Autostart {
  WindowsRunKeyAutostart({required this.executable, this.run = Process.run});

  final String executable;
  final Future<ProcessResult> Function(String, List<String>) run;

  static const key = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const valueName = _appName;

  /// The `reg` arguments that register or remove the login launch.
  static List<String> argumentsFor(bool on, String executable) => on
      ? [
          'add',
          key,
          '/v',
          valueName,
          '/t',
          'REG_SZ',
          '/d',
          commandFor(executable),
          '/f'
        ]
      : ['delete', key, '/v', valueName, '/f'];

  static String commandFor(String executable) =>
      '"$executable" $autostartArgument';

  /// The registered command out of `reg query` output, or null when absent.
  static String? registeredCommand(String queryOutput) {
    final match =
        RegExp(r'REG_SZ\s+(.+?)\s*$', multiLine: true).firstMatch(queryOutput);
    return match?.group(1);
  }

  @override
  Future<bool> isEnabled() async =>
      (await run('reg', ['query', key, '/v', valueName])).exitCode == 0;

  @override
  Future<void> repair() async {
    final result = await run('reg', ['query', key, '/v', valueName]);
    if (result.exitCode != 0) return;
    if (registeredCommand('${result.stdout}') != commandFor(executable)) {
      await setEnabled(true);
    }
  }

  @override
  Future<void> setEnabled(bool on) async {
    final result = await run('reg', argumentsFor(on, executable));
    if (result.exitCode != 0 && on) {
      throw ProcessException('reg', argumentsFor(on, executable),
          '${result.stderr}', result.exitCode);
    }
  }
}

/// SMAppService's main-app login item, answered by the macOS runner.
class MacLoginItemAutostart implements Autostart {
  static const _channel = MethodChannel('top.npcserver.slimm/autostart');

  Future<bool> isSupported() async =>
      await _channel.invokeMethod<bool>('isSupported') ?? false;

  @override
  Future<bool> isEnabled() async =>
      await _channel.invokeMethod<bool>('isEnabled') ?? false;

  @override
  Future<void> setEnabled(bool on) =>
      _channel.invokeMethod<void>('setEnabled', on);

  // SMAppService registers the bundle itself, whose path survives an update.
  @override
  Future<void> repair() async {}
}
