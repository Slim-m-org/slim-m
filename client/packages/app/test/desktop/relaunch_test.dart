// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The relaunch command is built, never run, here: what a test can pin is
/// that the child waits for this process to be gone before starting (the
/// single-instance runner would otherwise swallow it), that an AppImage runs
/// its image rather than its mounted path, and where no honest relaunch
/// exists.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/relaunch.dart';

({String program, List<String> arguments})? _command({
  String os = 'linux',
  Map<String, String> environment = const {},
  String executable = '/usr/lib/slim-m/slim-m',
}) => relaunchCommand(
  os: os,
  environment: environment,
  executable: executable,
  executableArguments: const ['--flag'],
  pid: 4242,
);

void main() {
  test('linux waits for this pid to exit, then execs the same executable', () {
    final command = _command()!;
    expect(command.program, '/bin/sh');
    expect(command.arguments[1], contains('kill -0 "\$1"'));
    expect(command.arguments[1], endsWith('exec "\$@"'));
    expect(command.arguments.sublist(3), [
      '4242',
      '/usr/lib/slim-m/slim-m',
      '--flag',
    ]);
  });

  test('macos takes the same waiting shape', () {
    expect(_command(os: 'macos')!.program, '/bin/sh');
  });

  test('an AppImage relaunches the image, not the mount that dies with it', () {
    final command = _command(
      environment: {'APPIMAGE': '/home/me/slim-m.AppImage'},
      executable: '/tmp/.mount_slimXYZ/usr/bin/slim-m',
    )!;
    expect(command.arguments, contains('/home/me/slim-m.AppImage'));
    expect(
      command.arguments,
      isNot(contains('/tmp/.mount_slimXYZ/usr/bin/slim-m')),
    );
  });

  test(
    'windows launches the executable, told to wait for this one to exit',
    () {
      final command = _command(
        os: 'windows',
        executable: r'C:\slim-m\slim-m.exe',
      )!;
      expect(command.program, r'C:\slim-m\slim-m.exe');
      expect(command.arguments, [windowsRelaunchArgument, '--flag']);
    },
  );

  test('flatpak and unknown platforms offer nothing', () {
    expect(
      _command(environment: {'FLATPAK_ID': 'top.npcserver.slimm'}),
      isNull,
    );
    expect(_command(os: 'fuchsia'), isNull);
  });
}
