// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The portable launcher names a too-old C library instead of the loader's bare error.
@TestOn('linux')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _launcherPath = '../../../packaging/linux/slim-m';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('slimm-launcher-');
    Directory('${dir.path}/bundle/lib').createSync(recursive: true);
    Directory('${dir.path}/bin').createSync();
    File(
      '${dir.path}/bundle/slim-m',
    ).writeAsStringSync(File(_launcherPath).readAsStringSync());
    File(
      '${dir.path}/bundle/slimm_app',
    ).writeAsStringSync('#!/bin/sh\nexit 0\n');
    Process.runSync('chmod', ['+x', '${dir.path}/bundle/slimm_app']);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  ProcessResult launch(String lddOutput) {
    File('${dir.path}/ldd.out').writeAsStringSync('$lddOutput\n');
    File(
      '${dir.path}/bin/ldd',
    ).writeAsStringSync("#!/bin/sh\ncat '${dir.path}/ldd.out'\n");
    Process.runSync('chmod', ['+x', '${dir.path}/bin/ldd']);
    return Process.runSync(
      'sh',
      ['${dir.path}/bundle/slim-m'],
      environment: {'PATH': '${dir.path}/bin:${Platform.environment['PATH']}'},
    );
  }

  test('a glibc version the system lacks is reported with the floor', () {
    final result = launch(
      "./lib/a.so: /lib/libc.so.6: version `GLIBC_2.38' not found (required by ./lib/a.so)",
    );
    expect(result.exitCode, 1);
    expect(result.stderr, contains('GLIBC_2.38'));
    expect(result.stderr, contains('glibc 2.38 or newer'));
  });

  test('a bundle the system can resolve starts', () {
    expect(launch('\tlibc.so.6 => /lib/libc.so.6').exitCode, 0);
  });
}
