// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The owner (backlog 2026-10-02): "this should just be a chat icon next to
/// the members list not a floating hash button". A voice call's text chat is
/// an app bar action at phone width, and nothing floats over the call stage.
///
/// Width alone picks the phone branch (docs/design/desktop-vs-mobile.md, the
/// one rule); the same toggle lives in the channel header at desktop width.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/screens/channel_screen.dart';
import 'package:slimm_app/src/features/voice/widgets/call_stage_layout.dart';
import 'package:slimm_app/src/features/channels/widgets/compact_channel_app_bar.dart';
import 'package:slimm_design_system/design_system.dart';

import '../settings/home_shell_harness.dart' show teardown;
import '../../support/call_screen_phone_harness.dart';

const _phone = Size(390, 844);

Finder get _toggle => find.bySemanticsLabel('Toggle text chat');

void main() {
  testWidgets('the call has no floating hash button', (tester) async {
    final s = await pumpCallScreen(tester, _phone);

    expect(find.byIcon(AppIcons.hash), findsNothing);
    await teardown(tester, s.container, s.db);
  });

  testWidgets('the chat icon sits in the app bar right beside members', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final s = await pumpCallScreen(tester, _phone);

    expect(
      find.descendant(of: find.byType(CompactChannelAppBar), matching: _toggle),
      findsOneWidget,
    );
    final chat = tester.getRect(_toggle);
    final members = tester.getRect(find.bySemanticsLabel('Show members'));
    expect(chat.right, members.left, reason: 'adjacent actions');
    expect(chat.top, members.top);
    expect(chat.width, greaterThanOrEqualTo(44));

    semantics.dispose();
    await teardown(tester, s.container, s.db);
  });

  testWidgets('the chat icon swaps the call for the chat and back', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final s = await pumpCallScreen(tester, _phone);
    expect(find.byType(CallStageLayout), findsOneWidget);
    expect(find.byType(ChannelScreen), findsNothing);

    await tester.tap(_toggle);
    await tester.pumpAndSettle();
    expect(find.byType(ChannelScreen), findsOneWidget);
    expect(find.byType(CallStageLayout), findsNothing);
    expect(find.byType(CompactChannelAppBar), findsOneWidget);

    await tester.tap(_toggle);
    await tester.pumpAndSettle();
    expect(find.byType(CallStageLayout), findsOneWidget);
    expect(find.byType(ChannelScreen), findsNothing);

    semantics.dispose();
    await teardown(tester, s.container, s.db);
  });

  testWidgets('coming back to the channel starts on the call, not the chat', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final s = await pumpCallScreen(tester, _phone);
    await tester.tap(_toggle);
    await tester.pumpAndSettle();
    expect(find.byType(ChannelScreen), findsOneWidget);

    s.router.go('/channels');
    await tester.pumpAndSettle();
    s.router.go('/channels/$callChannelId');
    await tester.pumpAndSettle();

    expect(find.byType(CallStageLayout), findsOneWidget);
    expect(find.byType(ChannelScreen), findsNothing);

    semantics.dispose();
    await teardown(tester, s.container, s.db);
  });

  testWidgets('the desktop header keeps its own chat toggle', (tester) async {
    final semantics = tester.ensureSemantics();
    final s = await pumpCallScreen(tester, const Size(1280, 800));

    expect(_toggle, findsOneWidget);
    expect(find.byType(CompactChannelAppBar), findsNothing);

    semantics.dispose();
    await teardown(tester, s.container, s.db);
  });
}
