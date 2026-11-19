// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a message row reads about its own message is let go when the row
/// leaves the screen: a session that scrolls past ten thousand messages must
/// not hold ten thousand of them.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/providers/button_presses.dart';
import 'package:slimm_app/src/features/messages/providers/message_actions.dart';
import 'package:slimm_app/src/features/messages/providers/poll_vote_failure.dart';

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  /// How many provider instances the container still holds for [family].
  int held(ProviderOrFamily family) => container
      .getAllProviderElements()
      .where((e) => e.provider.from == family)
      .length;

  /// Watches [provider] the way a mounted row does, then lets go as an unmounted one does.
  Future<void> watchThenLeave<T>(ProviderListenable<T> provider) async {
    container.listen<T>(provider, (_, _) {}).close();
    await container.pump();
  }

  test('a link preview row leaves nothing behind', () async {
    for (var i = 0; i < 50; i++) {
      await watchThenLeave(linkPreviewRemovalErrorProvider('m$i'));
    }
    expect(held(linkPreviewRemovalErrorProvider), 0);
  });

  test('a poll row leaves nothing behind', () async {
    for (var i = 0; i < 50; i++) {
      await watchThenLeave(pollVoteFailureProvider('m$i'));
    }
    expect(held(pollVoteFailureProvider), 0);
  });

  test('a row of bot buttons leaves nothing behind', () async {
    for (var i = 0; i < 50; i++) {
      await watchThenLeave(messageButtonPressesProvider('m$i'));
    }
    expect(held(messageButtonPressesProvider), 0);
  });

  test('a refusal is still there when its row comes back', () async {
    container
        .read(linkPreviewRemovalErrorsProvider.notifier)
        .put('m1', 'Could not remove the link previews.');
    container
        .read(pollVoteFailuresProvider.notifier)
        .put('m1', const PollVoteFailure('refused', PollBallot(option: 1)));
    await watchThenLeave(linkPreviewRemovalErrorProvider('m1'));
    await watchThenLeave(pollVoteFailureProvider('m1'));

    expect(
      container.read(linkPreviewRemovalErrorProvider('m1')),
      'Could not remove the link previews.',
    );
    expect(container.read(pollVoteFailureProvider('m1'))!.message, 'refused');
  });

  test('a cleared refusal holds nothing', () async {
    final notes = container.read(linkPreviewRemovalErrorsProvider.notifier)
      ..put('m1', 'refused')
      ..put('m1', null);
    expect(notes.state, isEmpty);
  });
}
