// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/self_update/self_update_failure.dart';
import 'package:slimm_app/src/desktop/self_update/windows_launcher_check.dart';
import 'package:slimm_app/src/desktop/self_update/windows_layout.dart';

void main() {
  late Directory root;
  late WindowsInstallLayout layout;

  setUp(() {
    root = Directory.systemTemp.createTempSync('slimm-launcher-check-');
    layout = WindowsInstallLayout(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  void writeLauncher(String text) =>
      File('${root.path}/slim-m.exe').writeAsStringSync(text);

  test('a launcher that knows the self-test is current', () async {
    writeLauncher('MZ....--launcher-selftest....');

    expect(await outdatedLauncherNotice(layout), isNull);
  });

  test('an old launcher is reported once, plainly', () async {
    writeLauncher('MZ....nothing about swapping....');

    final first = await outdatedLauncherNotice(layout);

    expect(first?.kind, SelfUpdateFailureKind.launcherOutdated);
    expect(first?.message, contains('Run the latest setup once'));
    expect(await outdatedLauncherNotice(layout), isNull);
  });

  test('no launcher means nothing to say', () async {
    expect(await outdatedLauncherNotice(layout), isNull);
  });
}
