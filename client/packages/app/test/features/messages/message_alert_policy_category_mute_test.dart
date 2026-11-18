// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A muted category keeps its channels and their threads from chiming, unless a channel has its own choice.
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

  test('a post in a muted category stays quiet, a mention too', () async {
    await wire(AlertRig()..mutedCategories = {'cat-1'});

    expect(await alertsFor(rig, alertMessage('group-1', 'hi all')), isFalse);
    expect(
      await alertsFor(
        rig,
        alertMessage('group-1', 'hi @nick', mentionsMe: true),
      ),
      isFalse,
    );
    expect(await alertsFor(rig, alertMessage('dm-1', 'hello')), isTrue);
  });

  test('a reply in a thread follows its parent channel\'s category', () async {
    await wire(AlertRig()..mutedCategories = {'cat-1'});

    expect(await alertsFor(rig, alertMessage('thread-1', 'reply')), isFalse);
  });

  test('a channel\'s own choice beats its category\'s mute', () async {
    await wire(
      AlertRig(overrides: {'group-1': 'everything'})
        ..mutedCategories = {'cat-1'},
    );

    expect(await alertsFor(rig, alertMessage('group-1', 'hi all')), isTrue);
  });

  test('another category\'s mute leaves it alone', () async {
    await wire(AlertRig()..mutedCategories = {'cat-2'});

    expect(await alertsFor(rig, alertMessage('group-1', 'hi all')), isTrue);
  });
}
