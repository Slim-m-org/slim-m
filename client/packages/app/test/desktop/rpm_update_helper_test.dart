// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The helper, its polkit action and the updater have to name the same path
/// and the same command; if they drift the password prompt comes back
/// without any test noticing.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/rpm_updater.dart';

String _read(String name) =>
    File('../../../packaging/rpm/$name').readAsStringSync();

void main() {
  final helper = _read(
    'slim-m-client-update-helper',
  ).split('\n').where((line) => !line.trimLeft().startsWith('#')).join('\n');
  final policy = _read(
    'top.npcserver.slimm.update.policy',
  ).replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
  final spec = _read('slim-m-client.spec');

  test('the policy annotates exactly the path the updater runs', () {
    expect(
      policy,
      contains(
        '<annotate key="org.freedesktop.policykit.exec.path">'
        '$rpmUpdateHelper</annotate>',
      ),
    );
  });

  test('the spec installs the helper where the updater looks for it', () {
    expect(rpmUpdateHelper, '/usr/libexec/$rpmPackage/update-helper');
    expect(spec, contains(r'%{_libexecdir}/%{name}/update-helper'));
    expect(spec, contains('Source13:       slim-m-client-update-helper'));
  });

  test('only an active local session skips the password', () {
    expect(RegExp('<action ').allMatches(policy), hasLength(1));
    expect(policy, contains('<allow_any>auth_admin</allow_any>'));
    expect(policy, contains('<allow_inactive>auth_admin</allow_inactive>'));
    expect(policy, contains('<allow_active>yes</allow_active>'));
  });

  test('the helper runs the one upgrade, by absolute path, in a clean env', () {
    final command = '/usr/bin/${rpmUpgradeCommand.join(' ')}';
    expect(helper, contains(command));
    expect(helper, contains('set -euo pipefail'));
    expect(helper, contains('/usr/bin/env -i'));
  });

  test('the helper never reads its arguments or the caller environment', () {
    for (final tainted in [r'$@', r'$*', r'$1', r'$HOME', r'$PATH', 'eval']) {
      expect(helper, isNot(contains(tainted)));
    }
  });
}
