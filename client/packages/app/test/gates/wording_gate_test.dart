// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The old spellings of the actions `ActionLabels` now owns never come back as
/// string literals in `lib/`, and the labels agree with the wording table.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/action_labels.dart';

const _retired = {
  'New role',
  'Add channel',
  'Add category',
  'Add emoji',
  'Issue a reset code',
  'Add a reaction',
  'Kick members',
  'Add a bot',
  'Add a webhook',
};

String _withoutComments(String source) => source
    .split('\n')
    .map((line) {
      final at = line.indexOf('//');
      return at < 0 ? line : line.substring(0, at);
    })
    .join('\n');

void main() {
  test('no retired spelling is a string literal in lib', () {
    final offenders = <String>[];
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      final code = _withoutComments(file.readAsStringSync());
      for (final retired in _retired) {
        if (code.contains("'$retired'") || code.contains('"$retired"')) {
          offenders.add('${file.path}: $retired');
        }
      }
    }
    expect(offenders, isEmpty);
  });

  test('every create action uses the one verb', () {
    for (final label in [
      ActionLabels.createChannel,
      ActionLabels.createCategory,
      ActionLabels.createRole,
      ActionLabels.createInvite,
      ActionLabels.createEmoji,
      ActionLabels.createBot,
      ActionLabels.createWebhook,
      ActionLabels.createResetCode,
    ]) {
      expect(label, startsWith('Create '));
    }
  });

  test('the two performance panes no longer share a name', () {
    expect(ActionLabels.mediaAndCache, isNot(ActionLabels.retentionAndLimits));
  });

  test('the wording table documents every label', () {
    final table = File('../../../docs/design/wording.md').readAsStringSync();
    for (final label in [
      ActionLabels.createChannel,
      ActionLabels.createRole,
      ActionLabels.addReaction,
      ActionLabels.removeMembers,
      ActionLabels.mediaAndCache,
      ActionLabels.retentionAndLimits,
      ActionLabels.operationsGroup,
    ]) {
      expect(table, contains(label));
    }
  });
}
