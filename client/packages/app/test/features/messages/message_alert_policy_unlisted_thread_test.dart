// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A thread this device never stored a row for still follows its parent channel's own choices.
library;

import 'package:flutter_test/flutter_test.dart';

import '../../support/message_alert_policy_rig.dart';

void main() {
  late AlertRig rig;

  Future<void> wire(AlertRig next) async {
    rig = next;
    await rig.start();
    addTearDown(rig.dispose);
  }

  test('a reply follows the parent channel loud override', () async {
    await wire(
      AlertRig(account: 'mentions', overrides: {'group-1': 'everything'}),
    );

    expect(await alertsFor(rig, alertMessage('thread-2', 'a reply')), isTrue);
  });

  test('a reply follows the parent channel mute', () async {
    await wire(AlertRig(overrides: {'group-1': 'nothing'}));

    expect(await alertsFor(rig, alertMessage('thread-2', 'a reply')), isFalse);
  });

  test('a reply follows the parent channel category mute', () async {
    await wire(AlertRig()..mutedCategories = {'cat-1'});

    expect(await alertsFor(rig, alertMessage('thread-2', 'a reply')), isFalse);
  });

  test('the parent is asked for once per thread', () async {
    await wire(AlertRig());

    await rig.policy.evaluate(alertMessage('thread-2', 'one'));
    await rig.policy.evaluate(alertMessage('thread-2', 'two'));

    expect(rig.threadParentRequests, ['/channels/thread-2/thread-parent']);
  });

  test('a channel that is not a thread follows the account', () async {
    await wire(
      AlertRig(account: 'mentions', overrides: {'group-1': 'everything'}),
    );

    expect(await alertsFor(rig, alertMessage('ghost-1', 'hi')), isFalse);
  });

  test('a failed parent lookup follows the account', () async {
    await wire(
      AlertRig(
        account: 'mentions',
        overrides: {'group-1': 'everything'},
        parentFails: true,
      ),
    );

    expect(await alertsFor(rig, alertMessage('thread-2', 'a reply')), isFalse);
  });
}
