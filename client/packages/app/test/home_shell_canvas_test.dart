// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the canvas pane's own presentation within [HomeShell]: it must
/// actually swap in for the conversation it replaces, must not leave the
/// header above it doubled up, and must fade through rather than teleport.
/// Split out of `home_shell_test.dart`, which owns the rest of the shell's
/// width-driven layout, to keep both files under this repo's file budget.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_fullscreen.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_app/src/screens/home_shell.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane.dart';
import 'package:slimm_app/src/features/channels/widgets/rail_drag_handle.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'home_shell_harness.dart';

/// A shell with one channel of [kind] open at [width], the canvas already
/// open for it before the first frame - "mounted with the provider set",
/// not opened by a later tap.
Future<({ProviderContainer container, SlimmDatabase db})> _pumpCanvasOpen(
  WidgetTester tester, {
  required double width,
  required String kind,
}) async {
  final s = setup(httpClient: quietClient(), signedIn: true);
  await MessageStore(s.db).upsertChannels([
    api.Channel(id: 'c1', name: 'general', kind: kind, createdAt: 0),
  ]);
  s.container.read(canvasOpenProvider.notifier).state = 'c1';
  await pumpAtWidth(tester, s.container, width, location: '/channels/c1');
  return s;
}

/// The [Opacity] [AppFadeIn] draws its content through, for whichever pane
/// is currently showing the [CanvasSurface].
Opacity _canvasOpacity(WidgetTester tester) => tester.widget<Opacity>(
  find
      .ancestor(of: find.byType(CanvasSurface), matching: find.byType(Opacity))
      .first,
);

void main() {
  /// The reachability guard `canvas_pane_test.dart` names only asserts that
  /// tapping the header flips a provider - nothing there ever mounts a real
  /// `ConversationPane`, so deleting `home_shell.dart`'s `canvasOpen` wiring
  /// left every test in that file green. This mounts the real thing with the
  /// provider already set and checks the canvas body itself is on screen,
  /// not the state that is supposed to produce it.
  testWidgets(
    'the canvas provider actually swaps in the canvas body, not just its own state',
    (tester) async {
      final s = await _pumpCanvasOpen(tester, width: 1400, kind: 'text');

      expect(find.byType(CanvasSurface), findsOneWidget);

      await teardown(tester, s.container, s.db);
    },
  );

  /// At compact width the outer header is the Scaffold's own app bar, built
  /// by `HomeShell` rather than `ConversationPane`, and it used to keep
  /// showing above the canvas: `CanvasBar`'s "Close canvas" is meant to be
  /// the only close affordance here, not a second one sitting above it.
  testWidgets('the compact app bar does not stack above the canvas', (
    tester,
  ) async {
    final s = await _pumpCanvasOpen(tester, width: 500, kind: 'text');

    expect(find.byType(CanvasSurface), findsOneWidget);
    expect(find.bySemanticsLabel('Close canvas'), findsOneWidget);
    expect(find.bySemanticsLabel('Open canvas'), findsNothing);

    await teardown(tester, s.container, s.db);
  });

  /// A voice channel wraps its body in a header of its own at any width both
  /// panes show, and that header used to keep showing above the canvas too:
  /// same duplication as the compact case, a different outer widget.
  testWidgets(
    'a voice channel does not stack its own header above the canvas',
    (tester) async {
      final s = await _pumpCanvasOpen(tester, width: 1400, kind: 'voice');

      expect(find.byType(CanvasSurface), findsOneWidget);
      expect(find.bySemanticsLabel('Close canvas'), findsOneWidget);
      expect(find.bySemanticsLabel('Open canvas'), findsNothing);

      await teardown(tester, s.container, s.db);
    },
  );

  /// Opening the canvas used to swap `ChannelScreen` for `CanvasPane`
  /// outright, an instant teleport with nothing in between - exactly the
  /// "screens appear rather than arrive" complaint. It now fades through
  /// like every other pane swap within a stable route.
  testWidgets(
    'opening the canvas over a channel fades through rather than teleporting',
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
      await pumpAtWidth(tester, s.container, 1400, location: '/channels/c1');
      expect(find.byType(CanvasSurface), findsNothing);

      s.container.read(canvasOpenProvider.notifier).state = 'c1';
      await tester.pump();

      // Freshly swapped in: AppFadeIn's own first frame lands at opacity zero.
      expect(_canvasOpacity(tester).opacity, 0);

      await tester.pumpAndSettle();
      expect(_canvasOpacity(tester).opacity, 1);

      await teardown(tester, s.container, s.db);
    },
  );

  /// Pumps the real [HomeShell], rail and member pane included, not just
  /// [ConversationPane] in isolation: those siblings used to trip an
  /// unrelated zero-duration `AnimatedSize` crash under reduce motion (see
  /// `AppMotion.reducedSize`'s doc comment), which is why this test once
  /// pumped `ConversationPane` alone to dodge it. Fixed now, so this drives
  /// the shell a viewer with the setting actually sees.
  testWidgets(
    'the canvas swap is instant under reduce motion, not merely faster',
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
      await pumpAtWidth(
        tester,
        s.container,
        1400,
        location: '/channels/c1',
        reduceMotion: true,
      );
      expect(find.byType(CanvasSurface), findsNothing);

      s.container.read(canvasOpenProvider.notifier).state = 'c1';
      await tester.pump();

      expect(
        tester.hasRunningAnimations,
        isFalse,
        reason: 'nothing may keep ticking once the viewer has asked it not to',
      );
      expect(_canvasOpacity(tester).opacity, 1);

      await teardown(tester, s.container, s.db);
    },
  );

  /// Fullscreen's whole desktop win is here rather than in the pane: at
  /// 1400 the rail and the roster are most of what surrounds the canvas, and
  /// both unmount rather than sitting at zero width, so neither keeps
  /// fetching behind a canvas that asked to be rid of them.
  testWidgets(
    'canvas fullscreen unmounts the rail, its handle and the member pane, '
    'and gives every pixel of all three to the surface',
    (tester) async {
      final s = await _pumpCanvasOpen(tester, width: 1400, kind: 'text');
      expect(find.byType(ChannelRail), findsOneWidget);
      expect(find.byType(AppMemberPane), findsOneWidget);
      final before = tester.getRect(find.byType(CanvasSurface)).width;

      s.container.read(canvasFullscreenProvider.notifier).state = 'c1';
      await tester.pumpAndSettle();

      expect(find.byType(ChannelRail), findsNothing);
      expect(find.byType(AppMemberPane), findsNothing);
      // A live control over a provider the shell is already overriding would read as broken rather than absent.
      expect(find.byType(RailDragHandle), findsNothing);
      expect(
        tester.getRect(find.byType(CanvasSurface)).width,
        greaterThan(before),
        reason: 'the surface must actually take the space, not just vacate it',
      );

      await teardown(tester, s.container, s.db);
    },
  );

  /// The provider is keyed on the channel for a reason, and this is it: a
  /// bare bool would leave a second channel's canvas fullscreen because the
  /// first one's was, with nothing to say why.
  testWidgets('fullscreen set for one channel does not reach another', (
    tester,
  ) async {
    final s = await _pumpCanvasOpen(tester, width: 1400, kind: 'text');

    s.container.read(canvasFullscreenProvider.notifier).state = 'some-other';
    await tester.pumpAndSettle();

    expect(find.byType(ChannelRail), findsOneWidget);
    expect(find.byType(AppMemberPane), findsOneWidget);

    await teardown(tester, s.container, s.db);
  });
}
