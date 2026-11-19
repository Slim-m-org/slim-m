// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An account switch mounts the next push-to-talk listener before the last
/// one is disposed; the old one leaving must not clear the new one's key.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/push_to_talk_key.dart';

void main() {
  final before = Object();
  final after = Object();
  tearDown(() => PushToTalkKey.withdraw(after));

  test('only the listener that published the key withdraws it', () {
    PushToTalkKey.publish(before, LogicalKeyboardKey.space);
    PushToTalkKey.publish(after, LogicalKeyboardKey.space);

    PushToTalkKey.withdraw(before);
    expect(PushToTalkKey.inWindow, LogicalKeyboardKey.space);

    PushToTalkKey.withdraw(after);
    expect(PushToTalkKey.inWindow, isNull);
  });
}
