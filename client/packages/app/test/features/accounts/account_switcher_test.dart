// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The switcher: what it lists, what its badges say, and what each row does.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/accounts/widgets/account_call_pill.dart';
import 'package:slimm_app/src/features/accounts/widgets/account_shortcuts.dart';
import 'package:slimm_app/src/features/accounts/widgets/account_switcher.dart';
import 'package:slimm_app/src/features/accounts/widgets/account_unread_badge.dart';
import 'package:slimm_design_system/design_system.dart';

import 'account_host_harness.dart';
import 'account_switcher_support.dart';

const _first = 'https://first.example';
const _second = 'https://second.example';

Widget _header() => const Padding(
  padding: EdgeInsets.all(16),
  child: AccountSwitcherTrigger(child: Text('Home')),
);

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(AccountSwitcherTrigger.triggerKey));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('with no account host it is only the child', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const ProviderScope(child: _SwitcherOnly()),
      ),
    );
    expect(find.text('Home'), findsOneWidget);
    expect(find.byKey(AccountSwitcherTrigger.triggerKey), findsNothing);
  });

  testWidgets('lists every server with the current one marked', (tester) async {
    final h = await twoServers(tester);
    await tester.pumpWidget(HostRoot(host: h.host, child: _header()));
    await _open(tester);

    expect(find.text('First'), findsOneWidget);
    expect(find.text('Second'), findsOneWidget);
    expect(find.text('second.example'), findsOneWidget);
    expect(find.text('Add a server'), findsOneWidget);
    expect(find.bySemanticsLabel('Sign out of Second'), findsOneWidget);
  });

  testWidgets('another server with unread shows a dot, and the trigger too', (
    tester,
  ) async {
    final h = await twoServers(tester);
    await tester.pumpWidget(HostRoot(host: h.host, child: _header()));
    await seedUnread(tester, h, _second);

    expect(find.byKey(AccountUnreadBadge.dotKey), findsOneWidget);
    await _open(tester);
    expect(find.byKey(AccountUnreadBadge.dotKey), findsNWidgets(2));
  });

  testWidgets('choosing a server switches to it and closes the menu', (
    tester,
  ) async {
    final h = await twoServers(tester);
    await tester.pumpWidget(HostRoot(host: h.host, child: _header()));
    await _open(tester);

    await tester.tap(find.text('Second'));
    await tester.pumpAndSettle();

    expect(h.host.active!.account!.origin, _second);
    expect(find.text('Add a server'), findsNothing);
  });

  testWidgets('Add a server opens an empty account to sign in with', (
    tester,
  ) async {
    final h = await twoServers(tester);
    await tester.pumpWidget(HostRoot(host: h.host, child: _header()));
    await _open(tester);

    await tester.tap(find.text('Add a server'));
    await tester.pumpAndSettle();

    expect(h.host.active!.account, isNull);
    expect(h.host.canCancelAdd, isTrue);
  });

  testWidgets('signing out of a server removes it from the list', (
    tester,
  ) async {
    final h = await twoServers(tester);
    await tester.pumpWidget(HostRoot(host: h.host, child: _header()));
    await _open(tester);

    await tester.tap(find.bySemanticsLabel('Sign out of Second'));
    await tester.pumpAndSettle();
    await tester.runAsync(pumpEventQueueTimes);
    await tester.pump();

    expect(h.host.accounts.map((r) => r.account!.origin), [_first]);
  });

  testWidgets('on a phone it opens as a bottom sheet', (tester) async {
    final h = await twoServers(tester, size: const Size(390, 844));
    await tester.pumpWidget(HostRoot(host: h.host, child: _header()));
    await _open(tester);

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('Add a server'), findsOneWidget);
  });

  testWidgets('Ctrl+2 jumps to the second server, Ctrl+9 to none', (
    tester,
  ) async {
    final h = await twoServers(tester);
    await tester.pumpWidget(HostRoot(host: h.host, child: const _Keys()));
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit9);
    await tester.pump();
    expect(h.host.active!.account!.origin, _first);

    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(h.host.active!.account!.origin, _second);
  });

  group('the call pill', () {
    testWidgets('shows for a call on another server and returns to it', (
      tester,
    ) async {
      final h = await twoServers(tester);
      await tester.pumpWidget(
        HostRoot(host: h.host, child: const AccountCallPill()),
      );
      expect(find.byKey(AccountCallPill.pillKey), findsNothing);

      h.host
              .runtimeFor(_first)!
              .container
              .read(testCallProvider.notifier)
              .state =
          connectedCall;
      await tester.pumpAndSettle();
      await h.host.switchTo(_second);
      await tester.pumpAndSettle();

      expect(find.text('In a call on First'), findsOneWidget);

      await tester.tap(find.byKey(AccountCallPill.pillKey));
      await tester.pumpAndSettle();

      expect(h.host.active!.account!.origin, _first);
      expect(find.byKey(AccountCallPill.pillKey), findsNothing);
    });

    testWidgets('is absent while the call is on the server in view', (
      tester,
    ) async {
      final h = await twoServers(tester);
      await tester.pumpWidget(
        HostRoot(host: h.host, child: const AccountCallPill()),
      );

      h.host
              .runtimeFor(_first)!
              .container
              .read(testCallProvider.notifier)
              .state =
          connectedCall;
      await tester.pumpAndSettle();

      expect(find.byKey(AccountCallPill.pillKey), findsNothing);
    });
  });
}

class _SwitcherOnly extends StatelessWidget {
  const _SwitcherOnly();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: AccountSwitcherTrigger(child: Text('Home')));
}

class _Keys extends ConsumerWidget {
  const _Keys();

  @override
  Widget build(BuildContext context, WidgetRef ref) => CallbackShortcuts(
    bindings: serverSwitchBindings(ref),
    child: const Focus(autofocus: true, child: Text('shell')),
  );
}
