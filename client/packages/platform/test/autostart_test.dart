// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/src/autostart.dart';
import 'package:slimm_platform/src/autostart_io.dart';
import 'package:slimm_platform/src/autostart_target.dart';

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

  group('login launch target', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('slimm-target-'));
    tearDown(() => root.deleteSync(recursive: true));

    String touch(String relative) {
      final file = File('${root.path}/$relative')..createSync(recursive: true);
      return file.path;
    }

    test('windows registers the root launcher of a managed install', () {
      final exe = touch('app-0.111.0/slimm_app.exe');
      touch('current');
      final launcher = touch('slim-m.exe');
      expect(windowsAutostartExecutable(exe), launcher);
    });

    test('windows keeps the exe for a bare copy or a missing pointer', () {
      final exe = touch('app-0.111.0/slimm_app.exe');
      touch('slim-m.exe');
      expect(windowsAutostartExecutable(exe), exe);
      final bare = touch('slim-m-bundle/slimm_app.exe');
      expect(windowsAutostartExecutable(bare), bare);
    });

    test('windows leaves Program Files and MSIX alone', () {
      const programFiles = r'C:\Program Files\slim-m\app-0.111.0\slimm_app.exe';
      expect(windowsAutostartExecutable(programFiles), programFiles);
    });

    test('linux registers current/slim-m of the tarball layout', () {
      final exe = touch('0.111.0/slimm_app');
      Link('${root.path}/current').createSync('0.111.0');
      expect(linuxAutostartExecutable(exe), '${root.path}/current/slim-m');
    });

    test('linux keeps the executable without a current symlink', () {
      final exe = touch('0.111.0/slimm_app');
      expect(linuxAutostartExecutable(exe), exe);
      expect(linuxAutostartExecutable('/usr/lib/slim-m/slimm_app'),
          '/usr/lib/slim-m/slimm_app');
    });
  });

  group('repairing an old registration', () {
    test('the xdg entry is rewritten when it names another executable',
        () async {
      final dir = Directory.systemTemp.createTempSync('slimm-autostart-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final entry = File('${dir.path}/top.npcserver.slimm.desktop')
        ..writeAsStringSync(XdgAutostart.desktopEntry('/r/0.1.0/slimm_app'));
      final autostart =
          XdgAutostart(entry: entry, executable: '/r/current/slim-m');
      await autostart.repair();
      expect(entry.readAsStringSync(), contains('Exec="/r/current/slim-m"'));
    });

    test('the xdg entry stays absent or hidden when off', () async {
      final dir = Directory.systemTemp.createTempSync('slimm-autostart-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final entry = File('${dir.path}/top.npcserver.slimm.desktop');
      final autostart = XdgAutostart(entry: entry, executable: 'x');
      await autostart.repair();
      expect(entry.existsSync(), isFalse);
      entry.writeAsStringSync('[Desktop Entry]\nHidden=true\n');
      await autostart.repair();
      expect(entry.readAsStringSync(), contains('Hidden=true'));
    });

    test('the run key is rewritten only when on and different', () async {
      final calls = <List<String>>[];
      Future<ProcessResult> reg(String cmd, List<String> args) async {
        calls.add(args);
        if (args.first == 'query') {
          return ProcessResult(
              1,
              0,
              '\r\nHKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Run\r\n'
                  '    slim-m    REG_SZ    "C:\\r\\app-0.1.0\\slimm_app.exe" --autostart\r\n',
              '');
        }
        return ProcessResult(1, 0, '', '');
      }

      await WindowsRunKeyAutostart(executable: r'C:\r\slim-m.exe', run: reg)
          .repair();
      expect(calls.last.first, 'add');
      expect(calls.last, contains(r'"C:\r\slim-m.exe" --autostart'));

      calls.clear();
      await WindowsRunKeyAutostart(
              executable: r'C:\r\app-0.1.0\slimm_app.exe', run: reg)
          .repair();
      expect(calls.map((c) => c.first), ['query']);
    });

    test('the run key is left alone when off', () async {
      final calls = <String>[];
      Future<ProcessResult> missing(String cmd, List<String> args) async {
        calls.add(args.first);
        return ProcessResult(1, 1, '', '');
      }

      await WindowsRunKeyAutostart(executable: 'x', run: missing).repair();
      expect(calls, ['query']);
    });
  });

  test('the login flag is the one the entries pass', () {
    expect(autostartArgument, '--autostart');
  });
}
