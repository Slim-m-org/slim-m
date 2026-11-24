// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A jump whose local store fails ends as a failed jump, not as Seeking forever.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/providers/message_jump.dart';
import 'package:slimm_app/src/providers/providers.dart';

void main() {
  test('a store error settles the jump on Failed', () async {
    final container = ProviderContainer(
      overrides: [
        storeProvider.overrideWith((ref) async => throw StateError('locked')),
      ],
    );
    addTearDown(container.dispose);
    final seen = <MessageJumpState>[];
    container.listen(messageJumpProvider, (_, next) => seen.add(next));

    await container.read(messageJumpProvider.notifier).jumpTo('c1', 'm1');

    expect(seen.first, isA<MessageJumpSeeking>());
    expect(container.read(messageJumpProvider), isA<MessageJumpFailed>());
  });
}
