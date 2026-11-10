// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sign-in screen says why it is in front of a share that is waiting.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/auth/screens/sign_in_reason_notices.dart';
import 'package:slimm_app/src/features/share/providers/incoming_share.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _app(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: const Scaffold(body: SignInReasonNotices()),
  ),
);

void main() {
  testWidgets('nothing is said when nothing is being shared', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(_app(container));

    expect(find.text('Sign in to finish sharing.'), findsNothing);
  });

  testWidgets('a waiting share is named, and the line goes once it is placed', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(pendingShareProvider.notifier).state = const PendingShare(
      IncomingShare(text: 'hello'),
    );

    await tester.pumpWidget(_app(container));
    expect(find.text('Sign in to finish sharing.'), findsOneWidget);

    container.read(pendingShareProvider.notifier).state = null;
    await tester.pump();
    expect(find.text('Sign in to finish sharing.'), findsNothing);
  });
}
