// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A search hit inside a thread opens the thread, not the thread's own id as
/// if it were a rail channel, which would show the parent channel's chrome.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_app/src/features/messages/widgets/message_jump.dart';

import '../../support/async_wait.dart';
import '../settings/home_shell_harness.dart';

void main() {
  testWidgets('jumping to a message in a thread opens the thread route', (
    tester,
  ) async {
    final s = setup(httpClient: quietClient(), signedIn: true);
    await pumpAtWidth(tester, s.container, 390);

    final router = tester.allElements
        .map(GoRouter.maybeOf)
        .firstWhere((router) => router != null)!;
    jumpToMessage(
      router,
      s.container.read,
      currentChannelId: null,
      channelId: 't1',
      messageId: 'm1',
      inThread: true,
    );
    await pumpFrames(tester);

    expect(find.text('thread t1'), findsOneWidget);
    expect(router.state.uri.path, '/thread/t1');

    await teardown(tester, s.container, s.db);
  });
}
