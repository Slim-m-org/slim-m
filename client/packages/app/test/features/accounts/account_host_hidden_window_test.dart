// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The host learns of a call on the account on screen while the window is in
/// the tray, when Flutter draws no frames and a derived provider never refreshes.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/window_lifecycle.dart';
import 'account_host_harness.dart';

const _a = 'https://first.example';
const _b = 'https://second.example';

void main() {
  testWidgets('a call that starts in a hidden window is known at once', (
    tester,
  ) async {
    final h = AccountHarness();
    await tester.runAsync(() async {
      await h.seed(_a, user: 'ann', active: true);
      await h.seed(_b, user: 'bea');
      await h.boot();
    });
    addTearDown(() => tester.runAsync(h.dispose));
    final onScreen = h.host.runtimeFor(_a)!;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: onScreen.container,
        child: const SizedBox(),
      ),
    );
    await tester.pump();
    expect(onScreen.inCall, isFalse);

    await hideTestWindow(tester);
    onScreen.container.read(testCallProvider.notifier).state = connectedCall;
    await tester.idle();

    expect(onScreen.inCall, isTrue);
    expect(h.host.callRuntime, onScreen);
  });

  testWidgets('an account removed in a hidden window is closed at once', (
    tester,
  ) async {
    final h = AccountHarness();
    await tester.runAsync(() async {
      await h.seed(_a, user: 'ann', active: true);
      await h.seed(_b, user: 'bea');
      await h.boot();
    });
    addTearDown(() => tester.runAsync(h.dispose));
    final removed = h.host.runtimeFor(_b)!.container;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.host.runtimeFor(_a)!.container,
        child: const SizedBox(),
      ),
    );

    await hideTestWindow(tester);
    await tester.runAsync(() async {
      await h.host.removeAccount(_b);
      await Future<void>.delayed(Duration.zero);
    });

    expect(() => removed.read(testCallProvider), throwsStateError);
  });

  testWidgets('an account removed on screen stays open until the next frame', (
    tester,
  ) async {
    final h = AccountHarness();
    await tester.runAsync(() async {
      await h.seed(_a, user: 'ann', active: true);
      await h.seed(_b, user: 'bea');
      await h.boot();
    });
    addTearDown(() => tester.runAsync(h.dispose));
    final removed = h.host.runtimeFor(_b)!.container;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.host.runtimeFor(_a)!.container,
        child: const SizedBox(),
      ),
    );

    await tester.runAsync(() async {
      await h.host.removeAccount(_b);
      await Future<void>.delayed(Duration.zero);
    });
    expect(() => removed.read(testCallProvider), returnsNormally);

    await tester.pump();
    expect(() => removed.read(testCallProvider), throwsStateError);
  });
}
