// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The browser's BroadcastChannel carries a tab's message to the other tabs and never back to itself.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/platform.dart';

void main() {
  test('a message reaches the other end and not the sender', () async {
    final sender = TabChannel('slimm.test.line');
    final receiver = TabChannel('slimm.test.line');
    final heardBySender = <String>[];
    final subscription = sender.messages.listen(heardBySender.add);
    addTearDown(subscription.cancel);

    final heard = receiver.messages.first.timeout(const Duration(seconds: 2));
    sender.post('hello');

    expect(await heard, 'hello');
    expect(heardBySender, isEmpty);
  }, skip: kIsWeb ? false : 'one process has no other tabs');

  test('without a browser the channel is silent and posting is harmless', () {
    if (kIsWeb) return;
    final channel = TabChannel('slimm.test.line');
    channel.post('ignored');
    expect(channel.messages, emitsDone);
  });
}
