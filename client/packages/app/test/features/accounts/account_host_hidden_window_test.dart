// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The host learns of a call on the account on screen while the window is in
/// the tray, when Flutter draws no frames and a derived provider never refreshes.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/accounts/providers/account_host.dart';

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

  testWidgets(
    'the account on screen removed in a hidden window stays open for its widgets',
    (tester) async {
      final h = AccountHarness();
      await tester.runAsync(() async {
        await h.seed(_a, user: 'ann', active: true);
        await h.seed(_b, user: 'bea');
        await h.boot();
      });
      addTearDown(() => tester.runAsync(h.dispose));
      final removed = h.host.runtimeFor(_a)!.container;
      await tester.pumpWidget(_AccountRoot(h.host));
      expect(_Probe.reads, 0);

      await hideTestWindow(tester);
      await tester.runAsync(() async {
        await h.host.removeAccount(_a);
        await Future<void>.delayed(Duration.zero);
      });
      // Its widgets are still mounted, and one of them reads on a timer.
      await tester.binding.delayed(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
      expect(_Probe.reads, greaterThan(0));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(h.host.active, h.host.runtimeFor(_b));
      expect(() => removed.read(testCallProvider), throwsStateError);
    },
  );

  testWidgets(
    'a frame drawn while the next account starts does not release the one on screen',
    (tester) async {
      final h = AccountHarness();
      await tester.runAsync(() async {
        await h.seed(_a, user: 'ann', active: true);
        await h.seed(_b, user: 'bea');
        await h.boot();
      });
      addTearDown(() => tester.runAsync(h.dispose));
      final removed = h.host.runtimeFor(_a)!.container;
      await tester.pumpWidget(_AccountRoot(h.host));
      late Future<void> removal;
      late Completer<void> finish;
      // Made outside the test's fake clock, whose microtasks would never run here.
      await tester.runAsync(() async {
        final started = Completer<void>();
        finish = Completer<void>();
        h.onActivate = (_) {
          started.complete();
          return finish.future;
        };
        removal = h.host.removeAccount(_a);
        await started.future;
      });
      await tester.pump();
      expect(h.host.active, h.host.runtimeFor(_b));
      await hideTestWindow(tester);
      await tester.runAsync(() async {
        finish.complete();
        await removal;
        await Future<void>.delayed(Duration.zero);
      });
      // The tree still shows the removed account, and its widgets read on a timer.
      await tester.binding.delayed(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
      expect(_Probe.reads, greaterThan(0));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(() => removed.read(testCallProvider), throwsStateError);
    },
  );

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

/// What `main.dart`'s `AccountRoot` does: the active container, keyed by it.
class _AccountRoot extends StatelessWidget {
  const _AccountRoot(this.host);

  final AccountHost host;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: host,
    builder: (context, _) {
      final container = host.active!.container;
      return UncontrolledProviderScope(
        key: ObjectKey(container),
        container: container,
        child: const _Probe(),
      );
    },
  );
}

/// A widget of the kind the app is full of: it reads its container from a timer.
class _Probe extends ConsumerStatefulWidget {
  const _Probe();

  static int reads = 0;

  @override
  ConsumerState<_Probe> createState() => _ProbeState();
}

class _ProbeState extends ConsumerState<_Probe> {
  late final Timer _timer;

  void _read() {
    ref.read(testCallProvider);
    _Probe.reads++;
  }

  @override
  void initState() {
    super.initState();
    _Probe.reads = 0;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _read());
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(testCallProvider);
    return const SizedBox();
  }
}
