// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The polkit rule the rpm ships has to authorize exactly the command
/// `RpmUpdater.apply` runs; if the two drift apart the password prompt comes
/// back without any test noticing.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/rpm_updater.dart';

void main() {
  final rule = File(
    '../../../packaging/rpm/49-slim-m-client-update.rules',
  ).readAsStringSync();
  final code = rule
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('//'))
      .join('\n');
  final literals = RegExp(
    r'"([^"]*)"',
  ).allMatches(code).map((m) => m.group(1)).toList();

  test('the rule authorizes exactly the command the updater runs', () {
    final commandLine = '/usr/bin/${rpmUpgradeCommand.join(' ')}';
    expect(literals, contains(commandLine));
    expect(literals, contains('/usr/bin/${rpmUpgradeCommand.first}'));
  });

  test('the rule is limited to active local wheel members', () {
    for (final guard in [
      'subject.local',
      'subject.active',
      'subject.isInGroup("wheel")',
    ]) {
      expect(code, contains(guard));
    }
  });

  test('the rule never grants a blanket yes', () {
    expect(RegExp('polkit\\.Result\\.YES').allMatches(code), hasLength(1));
    expect(code, contains('action.lookup("command_line")'));
  });
}
