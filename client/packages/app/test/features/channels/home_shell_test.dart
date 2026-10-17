// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the shell's width-driven layout: the member pane must not
/// merely be styled as hidden, it must not be built at all below expanded
/// width, and must appear once the window is wide enough.
///
/// Plus the compact layout's own regression: `ChannelHeader` is never built
/// at that width, and it used to be the only host of in-channel search, the
/// pinned-messages sheet, the channel topic and the member list, so all four
/// were unreachable on a phone. Each has a test here that drives the app bar
/// the way a thumb would.
///
/// The canvas pane's own swap within this shell is `home_shell_canvas_test.dart`,
/// split out to keep both files under this repo's file budget.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/screens/dm_call_pane.dart';
import 'package:slimm_app/src/features/voice/screens/voice_join_preview.dart'
    show VoiceRejoinScreen;
import 'package:slimm_app/src/features/channels/providers/threads.dart';
import 'package:slimm_app/src/features/messages/screens/thread_screen.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_search.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_api/api.dart' as api;

import '../settings/home_shell_harness.dart';

/// A phone-width shell with one channel open, seeded so the app bar has a
/// real name and topic to show.
Future<({ProviderContainer container, SlimmDatabase db})> _pumpCompactChannel(
  WidgetTester tester,
) async {
  final s = setup(httpClient: quietClient(), signedIn: true);
  await MessageStore(s.db).upsertChannels([
    const api.Channel(
      id: 'c1',
      name: 'general',
      kind: 'text',
      createdAt: 0,
      topic: 'Anything and everything',
    ),
  ]);
  await pumpAtWidth(tester, s.container, 500, location: '/channels/c1');
  return s;
}

/// `home_shell_canvas_test.dart`'s `_pumpCanvasOpen`, for a DM's call pane
/// rather than the canvas.
Future<({ProviderContainer container, SlimmDatabase db})> _pumpDmCallOpen(
  WidgetTester tester, {
  required double width,
  required String kind,
}) async {
  final s = setup(httpClient: quietClient(), signedIn: true);
  await MessageStore(s.db).upsertChannels([
    api.Channel(id: 'c1', name: 'Alice', kind: kind, createdAt: 0),
  ]);
  s.container.read(dmCallOpenProvider.notifier).state = 'c1';
  await pumpAtWidth(tester, s.container, width, location: '/channels/c1');
  return s;
}

void main() {
  testWidgets('the member pane is absent below expanded width', (tester) async {
    final s = setup();
    await pumpAtWidth(
      tester,
      s.container,
      700,
    ); // medium: two panes, no member pane.
    expect(find.byType(AppMemberPane), findsNothing);
    await teardown(tester, s.container, s.db);
  });

  testWidgets('narrowing the rail keeps it mounted at compact width, giving '
      'the transcript the difference', (tester) async {
    final s = setup();
    await pumpAtWidth(tester, s.container, 1400);
    expect(
      tester.getSize(find.byType(ChannelRail)).width,
      ChannelRail.expandedWidth,
    );

    s.container.read(channelRailExpandedProvider.notifier).state = false;
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byType(ChannelRail)).width,
      ChannelRail.compactWidth,
    );
    await teardown(tester, s.container, s.db);
  });

  testWidgets('the member pane appears at expanded width', (tester) async {
    final s = setup();
    await pumpAtWidth(tester, s.container, 1400);
    expect(find.byType(AppMemberPane), findsOneWidget);
    await teardown(tester, s.container, s.db);
  });

  testWidgets(
    'the member pane also docks at a wide-enough medium width, not only '
    'expanded - the owner\'s half-desktop-snap report at ~955px',
    (tester) async {
      final s = setup();
      await pumpAtWidth(tester, s.container, 955);
      expect(find.byType(AppMemberPane), findsOneWidget);
      await teardown(tester, s.container, s.db);
    },
  );

  testWidgets(
    'an open thread docks beside the transcript at expanded width, and the '
    'roster yields the third-pane slot to it (UX1)',
    (tester) async {
      final s = setup();
      await pumpAtWidth(tester, s.container, 1400);
      expect(find.byType(AppMemberPane), findsOneWidget);
      expect(find.byType(ThreadScreen), findsNothing);

      s.container.read(openThreadProvider.notifier).state = 'c-thread';
      await tester.pumpAndSettle();

      expect(
        find.byType(ThreadScreen),
        findsOneWidget,
        reason: 'the thread is a docked side pane, not a modal over the shell',
      );
      expect(
        find.byType(AppMemberPane),
        findsNothing,
        reason: 'the roster and the thread never both take the third-pane slot',
      );
      await teardown(tester, s.container, s.db);
    },
  );

  testWidgets(
    'below the width that fits the thread pane, an open thread does not dock - '
    'the compact/deep-link modal route is kept',
    (tester) async {
      final s = setup();
      // Medium: two panes fit, but not a 360px thread pane and a transcript.
      await pumpAtWidth(tester, s.container, 700);
      s.container.read(openThreadProvider.notifier).state = 'c-thread';
      await tester.pumpAndSettle();
      expect(find.byType(ThreadScreen), findsNothing);
      await teardown(tester, s.container, s.db);
    },
  );

  testWidgets(
    'the member toggle shows only where the pane can, not at medium width',
    (tester) async {
      final s = setup(httpClient: quietClient(), signedIn: true);
      await MessageStore(s.db).upsertChannels([
        const api.Channel(
          id: 'c1',
          name: 'general',
          kind: 'text',
          createdAt: 0,
        ),
      ]);

      // Expanded: the pane can show, so the header offers its toggle.
      await pumpAtWidth(tester, s.container, 1400, location: '/channels/c1');
      expect(find.bySemanticsLabel('Toggle member list'), findsOneWidget);

      // Medium: the pane never docks here, so no lit toggle; the roster opens as a drawer instead (home_shell_medium_members_test.dart).
      await pumpAtWidth(tester, s.container, 700, location: '/channels/c1');
      expect(find.byType(AppMemberPane), findsNothing);
      expect(find.bySemanticsLabel('Toggle member list'), findsNothing);

      // A wider medium window has the same room expanded always did, so the
      // toggle and the pane agree there too.
      await pumpAtWidth(tester, s.container, 955, location: '/channels/c1');
      expect(find.byType(AppMemberPane), findsOneWidget);
      expect(find.bySemanticsLabel('Toggle member list'), findsOneWidget);

      await teardown(tester, s.container, s.db);
    },
  );

  testWidgets(
    'hiding the pane at expanded width removes it, not just styles it',
    (tester) async {
      final s = setup();
      await pumpAtWidth(tester, s.container, 1400);
      expect(find.byType(AppMemberPane), findsOneWidget);

      s.container.read(memberPaneVisibleProvider.notifier).state = false;
      await tester.pumpAndSettle();
      expect(find.byType(AppMemberPane), findsNothing);

      await teardown(tester, s.container, s.db);
    },
  );

  testWidgets('the channel topic is on screen at compact width', (
    tester,
  ) async {
    final s = await _pumpCompactChannel(tester);

    expect(find.text('general'), findsOneWidget);
    expect(
      find.text('Anything and everything'),
      findsOneWidget,
      reason:
          'the topic only ever lived in ChannelHeader, which this '
          'width never builds',
    );

    await teardown(tester, s.container, s.db);
  });

  testWidgets('search opens from the compact app bar', (tester) async {
    final s = await _pumpCompactChannel(tester);

    expect(find.byType(ChannelSearchBar), findsNothing);
    await tester.tap(find.bySemanticsLabel('Search messages'));
    await tester.pumpAndSettle();
    expect(find.byType(ChannelSearchBar), findsOneWidget);

    // And closes again, since the same control is the only way back.
    await tester.tap(find.bySemanticsLabel('Search messages'));
    await tester.pumpAndSettle();
    expect(find.byType(ChannelSearchBar), findsNothing);

    await teardown(tester, s.container, s.db);
  });

  testWidgets('the pinned-messages sheet opens from the compact app bar', (
    tester,
  ) async {
    final s = await _pumpCompactChannel(tester);

    await tester.tap(find.bySemanticsLabel('Pinned messages, 0'));
    await tester.pumpAndSettle();
    expect(find.text('Pinned messages'), findsOneWidget);
    expect(find.text('Nothing pinned yet.'), findsOneWidget);

    // Dismissed before teardown so the route stack unwinds normally.
    Navigator.of(tester.element(find.text('Pinned messages'))).pop();
    await tester.pumpAndSettle();

    await teardown(tester, s.container, s.db);
  });

  testWidgets('the member list opens from the compact app bar', (tester) async {
    final s = await _pumpCompactChannel(tester);

    expect(find.byType(AppMemberPane), findsNothing);
    await tester.tap(find.bySemanticsLabel('Show members'));
    await tester.pumpAndSettle();
    expect(
      find.byType(AppMemberPane),
      findsOneWidget,
      reason:
          'the roster has no room to dock beside the conversation at '
          'this width, so the app bar has to summon it',
    );

    await teardown(tester, s.container, s.db);
  });

  /// The real pane has to swap in, not merely the state that is supposed to
  /// drive it; `home_shell_canvas_test.dart` carries the canvas's equivalent
  /// of this test.
  testWidgets(
    'the dm call provider actually swaps in the voice screen, not just its own state',
    (tester) async {
      final s = await _pumpDmCallOpen(tester, width: 1400, kind: 'dm');

      expect(find.byType(VoiceRejoinScreen), findsOneWidget);

      await teardown(tester, s.container, s.db);
    },
  );

  /// The DM call pane replaces the header the same way the canvas does; see
  /// `DmCallPane`'s doc.
  testWidgets('the compact app bar does not stack above a DM call', (
    tester,
  ) async {
    final s = await _pumpDmCallOpen(tester, width: 500, kind: 'dm');

    expect(find.byType(VoiceRejoinScreen), findsOneWidget);
    expect(find.bySemanticsLabel('Back to messages'), findsOneWidget);
    expect(find.bySemanticsLabel('Search messages'), findsNothing);

    await teardown(tester, s.container, s.db);
  });

  /// `dmCallOpenProvider` is read unconditionally by two "back to the call"
  /// affordances outside a DM (`RailCallSummary`, `VoiceStripIndicator`), so
  /// setting it for a channel that never turns out to be a DM must stay
  /// inert rather than hijacking an ordinary text channel's pane.
  testWidgets('the dm call provider does nothing for a text channel', (
    tester,
  ) async {
    final s = await _pumpDmCallOpen(tester, width: 1400, kind: 'text');

    expect(find.byType(DmCallPane), findsNothing);
    expect(find.byType(VoiceRejoinScreen), findsNothing);

    await teardown(tester, s.container, s.db);
  });
}
