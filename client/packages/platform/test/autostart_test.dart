// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/src/autostart.dart';
import 'package:slimm_platform/src/autostart_io.dart';

void main() {
  group('XDG autostart', () {
    test('the entry lives under XDG_CONFIG_HOME, or ~/.config without it', () {
      expect(
        XdgAutostart.entryFor({'HOME': '/home/a', 'XDG_CONFIG_HOME': '/cfg'})
            .path,
        '/cfg/autostart/top.npcserver.slimm.desktop',
      );
      expect(
        XdgAutostart.entryFor({'HOME': '/home/a'}).path,
        '/home/a/.config/autostart/top.npcserver.slimm.desktop',
      );
    });

    test('the entry launches the quoted executable with the login flag', () {
      final entry = XdgAutostart.desktopEntry('/opt/slim m/slimm_app');
      expect(entry, startsWith('[Desktop Entry]\n'));
      expect(entry, contains('Type=Application\n'));
      expect(entry, contains('Exec="/opt/slim m/slimm_app" --autostart\n'));
      expect(entry, contains('Icon=top.npcserver.slimm\n'));
    });

    test(
        'turning it on writes the entry and off removes it, read back each time',
        () async {
      final dir = Directory.systemTemp.createTempSync('slimm-autostart-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final autostart = XdgAutostart(
        entry: File('${dir.path}/autostart/top.npcserver.slimm.desktop'),
        executable: '/usr/bin/slim-m',
      );
      expect(await autostart.isEnabled(), isFalse);
      await autostart.setEnabled(true);
      expect(await autostart.isEnabled(), isTrue);
      expect(autostart.entry.readAsStringSync(),
          contains('Exec="/usr/bin/slim-m" --autostart'));
      await autostart.setEnabled(false);
      expect(await autostart.isEnabled(), isFalse);
      expect(autostart.entry.existsSync(), isFalse);
    });

    test('an entry the desktop marked hidden reads as off', () async {
      final dir = Directory.systemTemp.createTempSync('slimm-autostart-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/top.npcserver.slimm.desktop')
        ..writeAsStringSync('[Desktop Entry]\nHidden=true\n');
      expect(await XdgAutostart(entry: file, executable: 'x').isEnabled(),
          isFalse);
    });
  });

  group('Windows Run key', () {
    test('on adds the quoted executable with the login flag, off deletes it',
        () {
      expect(
          WindowsRunKeyAutostart.argumentsFor(
              true, r'C:\Program Files\slim-m\slimm_app.exe'),
          [
            'add',
            r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
            '/v',
            'slim-m',
            '/t',
            'REG_SZ',
            '/d',
            r'"C:\Program Files\slim-m\slimm_app.exe" --autostart',
            '/f',
          ]);
      expect(
        WindowsRunKeyAutostart.argumentsFor(false, 'x'),
        [
          'delete',
          r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
          '/v',
          'slim-m',
          '/f'
        ],
      );
    });

    test('it reads as on only when reg finds the value', () async {
      Future<ProcessResult> found(String cmd, List<String> args) async =>
          ProcessResult(1, 0, '', '');
      Future<ProcessResult> missing(String cmd, List<String> args) async =>
          ProcessResult(1, 1, '', '');
      expect(
          await WindowsRunKeyAutostart(executable: 'x', run: found).isEnabled(),
          isTrue);
      expect(
          await WindowsRunKeyAutostart(executable: 'x', run: missing)
              .isEnabled(),
          isFalse);
    });
  });

  test('the login flag is the one the entries pass', () {
    expect(autostartArgument, '--autostart');
  });
}
