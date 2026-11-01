// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Bringing up a fresh copy of this app from inside it: the title bar's
/// Restart, and the splash's restart into a just-installed update.
///
/// The new copy must not start until this one has gone. The Linux runner is
/// a single-instance GtkApplication (`linux_second_instance_channel.cc`): a
/// second launch while the first still holds the bus name only activates the
/// first, which is about to exit, and nothing comes back. So on Linux and
/// macOS the child is a shell that waits for this pid to disappear and then
/// execs the app. The Windows runner is single-instance too, by a named
/// mutex (`single_instance.cpp`), and [windowsRelaunchArgument] makes the new
/// copy wait on it rather than hand focus to this one. Detached either way, or this process's exit would take the
/// child with it.
///
/// Not offered under flatpak: the sandbox ends with its main process, and
/// `flatpak-spawn --host` needs a bus name the manifest does not grant.
library;

import 'dart:io';

import 'self_update/self_update_target.dart';

/// Matches `kRelaunchArgument` in the Windows runner's `single_instance.h`.
const windowsRelaunchArgument = '--relaunch';

/// The program and arguments that start a fresh copy once process [pid] has
/// exited, or null where no honest relaunch exists on this platform.
({String program, List<String> arguments})? relaunchCommand({
  required String os,
  required Map<String, String> environment,
  required String executable,
  required List<String> executableArguments,
  required int pid,
}) {
  if (environment.containsKey('FLATPAK_ID')) return null;
  // An AppImage's mounted executable path dies with the process; the image itself is what to run again.
  final program = environment['APPIMAGE'] ?? executable;
  return switch (os) {
    'windows' => (
      program: program,
      arguments: [windowsRelaunchArgument, ...executableArguments],
    ),
    'linux' || 'macos' => (
      program: '/bin/sh',
      arguments: [
        '-c',
        r'while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; shift; exec "$@"',
        'slim-m-relaunch',
        '$pid',
        program,
        ...executableArguments,
      ],
    ),
    _ => null,
  };
}

/// Set once a bare Windows copy has moved itself into the per-user layout:
/// this process still runs from the old folder, but a restart belongs to the
/// launcher there.
String? relaunchLauncherOverride;

/// In the per-user layout the launcher, so a restart lands on whichever
/// version `current` names; otherwise the running executable.
String _executableToRun() {
  final executable = Platform.resolvedExecutable;
  final target = installTargetFor(executable, Platform.operatingSystem);
  return target?.launcher.path ?? relaunchLauncherOverride ?? executable;
}

({String program, List<String> arguments})? _thisProcessCommand([
  String? executable,
]) => relaunchCommand(
  os: Platform.operatingSystem,
  environment: Platform.environment,
  executable: executable ?? _executableToRun(),
  executableArguments: Platform.executableArguments,
  pid: pid,
);

/// Whether [spawnRelaunch] can do anything for this process.
bool canRelaunchThisProcess() => _thisProcessCommand() != null;

/// Starts the detached child that brings the app back once this process has
/// exited. The caller quits afterwards; this never does. [executable] names
/// what to start when it is not this process's own install.
Future<void> spawnRelaunch({String? executable}) async {
  final command = _thisProcessCommand(executable);
  if (command == null) return;
  await Process.start(
    command.program,
    command.arguments,
    mode: ProcessStartMode.detached,
  );
}
