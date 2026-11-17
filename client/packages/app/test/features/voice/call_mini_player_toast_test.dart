// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A toast on a wide window rises above the call mini-player resting in the
/// bottom-right corner, and above a bottom dock, rather than covering them.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/widgets/call_mini_player.dart';
import 'package:slimm_app/src/providers/dock_reservation.dart';
import 'package:slimm_app/src/providers/toasts.dart';

import '../../ui_snapshot_support.dart';
import 'call_mini_player_harness.dart';

void main() {
  setUpAll(loadRealFonts);

  testWidgets('a toast clears a bottom-right mini-player', (tester) async {
    final ctx = await pumpMini(
      tester,
      location: '/channels/c-general',
      voice: miniCall([remoteShare]),
      size: desktopSize,
    );
    await settleMini(tester);

    ctx.container.read(toastsProvider.notifier).show('Could not save it.');
    await tester.pump(const Duration(milliseconds: 400));

    final card = tester.getRect(find.byKey(miniPlayerKey));
    final toast = tester.getRect(find.text('Could not save it.'));
    expect(toast.bottom, lessThanOrEqualTo(card.top));
    await tester.pump(ToastsController.defaultDuration);
    await ctx.done();
  });

  testWidgets('a toast clears a reported bottom dock', (tester) async {
    final ctx = await pumpMini(
      tester,
      location: '/channels/c-general',
      voice: miniCall(const []),
      size: desktopSize,
    );
    ctx.container.read(bottomDockReservationProvider.notifier).state = 120;
    ctx.container.read(toastsProvider.notifier).show('Could not save it.');
    await tester.pump(const Duration(milliseconds: 400));

    final toast = tester.getRect(find.text('Could not save it.'));
    expect(toast.bottom, lessThanOrEqualTo(desktopSize.height - 120));
    await tester.pump(ToastsController.defaultDuration);
    await ctx.done();
  });
}
