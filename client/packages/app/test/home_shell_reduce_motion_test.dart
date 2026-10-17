// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Drives the real [HomeShell] under global reduce motion, not just a pane
/// pumped in isolation.
///
/// `RailConnectionBar` and `RailUserFooter` (`channel_rail_frame.dart`) each
/// wrap an `AnimatedSize` whose duration used to route through
/// `AppMotion.reduced`, which collapses to a literal [Duration.zero] under
/// this setting. `RenderAnimatedSize` restarts its own `AnimationController`
/// whenever its child's size changes, and a zero-duration controller
/// completes and notifies synchronously rather than on the next tick - so a
/// child that changes size twice before the animation would have settled
/// re-enters `markNeedsLayout` on the very `RenderObject` still inside its
/// own `performLayout`, which Flutter asserts against ("A RenderAnimatedSize
/// was mutated in its own performLayout implementation").
///
/// `AppMotion.reducedSize` (see its own doc comment) is the fix, and this
/// file is what proves it holds through the real shell rather than only the
/// isolated widget `reduce_motion_test.dart` (in `design_system`) checks.
/// `home_shell_canvas_test.dart`'s reduce-motion test used to pump
/// `ConversationPane` alone to dodge this crash; it now drives the shell
/// too.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_api/api.dart' as api;

import 'features/settings/home_shell_harness.dart';

void main() {
  /// The rail and member pane both toggle, and the connection bar's own
  /// `AnimatedSize` cycles through every status it renders differently
  /// (`RailConnectionBar`'s child is a zero-height `SizedBox` only at
  /// `live`), which is the exact shape that used to crash.
  testWidgets(
    'the expanded shell survives every rail and member-pane transition '
    'under reduce motion',
    (tester) async {
      final s = setup();
      await pumpAtWidth(tester, s.container, 1400, reduceMotion: true);

      s.container.read(channelRailExpandedProvider.notifier).state = false;
      await tester.pumpAndSettle();
      s.container.read(channelRailExpandedProvider.notifier).state = true;
      await tester.pumpAndSettle();

      s.container.read(memberPaneVisibleProvider.notifier).state = false;
      await tester.pumpAndSettle();
      s.container.read(memberPaneVisibleProvider.notifier).state = true;
      await tester.pumpAndSettle();

      for (final status in [
        SyncStatus.live,
        SyncStatus.offline,
        SyncStatus.connecting,
        SyncStatus.live,
      ]) {
        s.container.read(syncControllerProvider.notifier).state = status;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();

      expect(find.byType(ChannelRail), findsOneWidget);
      await teardown(tester, s.container, s.db);
    },
  );

  /// The compact scaffold mounts `RailConnectionBar` directly (`home_shell
  /// .dart`'s `else if (selected != null)` branch), outside `ChannelRail`
  /// entirely, so it needs its own pass through the same status cycle.
  testWidgets(
    'the compact shell survives a connection-status cycle under reduce '
    'motion',
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
        500,
        location: '/channels/c1',
        reduceMotion: true,
      );

      for (final status in [SyncStatus.live, SyncStatus.offline]) {
        s.container.read(syncControllerProvider.notifier).state = status;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();

      await teardown(tester, s.container, s.db);
    },
  );
}
