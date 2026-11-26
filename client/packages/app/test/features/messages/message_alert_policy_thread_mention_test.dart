// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A reply in a thread you started or replied in counts as a mention, so it alerts under Mentions only.
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

  Future<void> replyInThread(String content) =>
      rig.store.applyMessage(alertMessage('thread-2', content, authorId: 'me'));

  Future<bool> alertsForReply() async {
    final alert = await rig.policy.evaluate(alertMessage('thread-2', 'next'));
    return alert != null;
  }

  test('a reply in a thread you started alerts under Mentions only', () async {
    await wire(AlertRig(account: 'mentions', parentAuthorId: 'me'));

    final alert = await rig.policy.evaluate(alertMessage('thread-2', 'hi'));

    expect(alert?.mentionsSelf, isTrue);
  });

  test(
    'a reply in a thread you replied in alerts under Mentions only',
    () async {
      await wire(AlertRig(account: 'mentions', parentAuthorId: 'alice'));
      await replyInThread('mine');

      expect(await alertsForReply(), isTrue);
    },
  );

  test(
    'a reply in a thread you are not in stays quiet under Mentions only',
    () async {
      await wire(AlertRig(account: 'mentions', parentAuthorId: 'alice'));

      expect(await alertsForReply(), isFalse);
    },
  );

  test(
    'a reply in a channel only you wrote in is not a thread mention',
    () async {
      await wire(AlertRig(account: 'mentions'));
      await rig.store.applyMessage(
        alertMessage('group-1', 'mine', authorId: 'me'),
      );

      final alert = await rig.policy.evaluate(alertMessage('group-1', 'next'));

      expect(alert, isNull);
    },
  );

  test('muting the thread or its channel still silences it', () async {
    await wire(
      AlertRig(
        account: 'mentions',
        parentAuthorId: 'me',
        overrides: {'thread-2': 'nothing'},
      ),
    );
    expect(await alertsForReply(), isFalse);
    await rig.dispose();

    await wire(
      AlertRig(
        account: 'mentions',
        parentAuthorId: 'me',
        overrides: {'group-1': 'nothing'},
      ),
    );
    expect(await alertsForReply(), isFalse);
  });

  test('your own reply never alerts you', () async {
    await wire(AlertRig(account: 'mentions', parentAuthorId: 'me'));

    final alert = await rig.policy.evaluate(
      alertMessage('thread-2', 'mine', authorId: 'me'),
    );

    expect(alert, isNull);
  });
}
