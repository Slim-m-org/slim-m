// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Mounts the active account's container the way main.dart does, around a
/// widget under test.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/accounts/providers/account_host.dart';
import 'package:slimm_design_system/design_system.dart';

import 'package:slimm_app/src/providers/providers.dart' show storeProvider;
import 'account_host_harness.dart';

/// Rebuilds around whichever container the host calls active.
class HostRoot extends StatelessWidget {
  const HostRoot({
    super.key,
    required this.host,
    required this.child,
    this.dark = false,
    this.boundary,
  });

  final AccountHost host;
  final Widget child;
  final bool dark;
  final Key? boundary;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: host,
    builder: (context, _) {
      final container = host.active!.container;
      return UncontrolledProviderScope(
        key: ObjectKey(container),
        container: container,
        child: RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: dark
                ? buildTheme(Brightness.dark, AppTokens.dark)
                : buildTheme(Brightness.light, AppTokens.light),
            home: Scaffold(body: child),
          ),
        ),
      );
    },
  );
}

/// Two signed-in servers, the first on screen, on a view [size] wide.
Future<AccountHarness> twoServers(
  WidgetTester tester, {
  Size size = const Size(1280, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = AccountHarness();
  await tester.runAsync(() async {
    await h.seed('https://first.example', user: 'ann', active: true);
    await h.seed('https://second.example', user: 'bea');
    await h.boot();
  });
  addTearDown(() => tester.runAsync(h.dispose));
  return h;
}

/// Gives [origin] an unread channel, and a mentioned one when [mention].
Future<void> seedUnread(
  WidgetTester tester,
  AccountHarness h,
  String origin, {
  bool mention = false,
}) async {
  await tester.runAsync(() async {
    final runtime = h.host.runtimeFor(origin)!;
    final store = await runtime.container.read(storeProvider.future);
    await store.upsertChannels([
      const api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 0),
      const api.Channel(id: 'c2', name: 'random', kind: 'text', createdAt: 0),
    ]);
    await store.applyMessages([
      const api.Message(
        id: 'm1',
        channelId: 'c1',
        authorId: 'friend',
        authorDisplayName: 'friend',
        seq: 1,
        content: 'hello',
        createdAt: 1000,
        editedAt: null,
      ),
      if (mention)
        const api.Message(
          id: 'm2',
          channelId: 'c2',
          authorId: 'friend',
          authorDisplayName: 'friend',
          seq: 1,
          content: 'ping',
          createdAt: 1000,
          editedAt: null,
          mentionsMe: true,
        ),
    ]);
    await pumpEventQueueTimes();
  });
  await tester.pump();
}
