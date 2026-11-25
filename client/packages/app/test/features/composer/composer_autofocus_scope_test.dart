// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A request to focus the docked thread's composer leaves the channel's own
/// composer, beside it, alone.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/providers/threads.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_autofocus.dart';

void main() {
  testWidgets('only the docked thread composer takes the focus request', (
    tester,
  ) async {
    final channelNode = FocusNode();
    final threadNode = FocusNode();
    addTearDown(channelNode.dispose);
    addTearDown(threadNode.dispose);
    final container = ProviderContainer(
      overrides: [
        dockedThreadsProvider.overrideWith((ref) => const {'c1': 't1'}),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Material(
            child: Row(
              children: [
                Expanded(
                  child: ComposerAutofocus(
                    channelId: 't1',
                    focusOnMount: false,
                    child: TextField(focusNode: threadNode),
                  ),
                ),
                Expanded(
                  child: ComposerAutofocus(
                    channelId: 'c1',
                    focusOnMount: false,
                    child: TextField(focusNode: channelNode),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    var channelGainedFocus = false;
    channelNode.addListener(() => channelGainedFocus |= channelNode.hasFocus);

    container.read(threadComposerFocusRequestProvider.notifier).state++;
    await tester.pump();

    expect(threadNode.hasFocus, isTrue);
    expect(channelGainedFocus, isFalse);
  });
}
