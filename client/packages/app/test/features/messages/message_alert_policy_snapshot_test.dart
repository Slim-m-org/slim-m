// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The policy runs for every incoming message, so it reads a channel's row
/// once instead of opening a drift stream query it cancels straight away.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_data/data.dart';

import '../../support/message_alert_policy_rig.dart';

class _WatchCountingStore extends MessageStore {
  _WatchCountingStore(super.db);

  int watches = 0;

  @override
  Stream<Channel?> watchChannelRow(String channelId) {
    watches++;
    return super.watchChannelRow(channelId);
  }
}

void main() {
  late _WatchCountingStore store;
  late AlertRig rig;

  setUp(() async {
    rig = AlertRig(makeStore: (db) => store = _WatchCountingStore(db));
    await rig.start();
    addTearDown(rig.dispose);
  });

  test('a channel message reads its row without a stream', () async {
    expect(await alertsFor(rig, alertMessage('group-1', 'hello')), isTrue);

    expect(store.watches, 0);
  });

  test(
    'a thread reply reads the thread and its parent without a stream',
    () async {
      expect(await alertsFor(rig, alertMessage('thread-1', 'a reply')), isTrue);

      expect(store.watches, 0);
    },
  );
}
