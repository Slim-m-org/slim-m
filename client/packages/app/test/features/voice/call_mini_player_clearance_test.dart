// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The mini-player keeps clear of the newest messages and remembers where it
/// was put across calls on this device.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/call_mini_player.dart';
import 'package:slimm_app/src/features/voice/widgets/call_mini_player.dart';
import 'package:slimm_app/src/providers/providers.dart';

import '../../ui_snapshot_support.dart';
import 'call_mini_player_harness.dart';

const _newest = 'Passing this along with a note of my own.';

void main() {
  setUpAll(loadRealFonts);
  final player = find.byKey(miniPlayerKey);

  for (final (name, size) in [('wide', desktopSize), ('phone', phoneSize)]) {
    testWidgets('the newest message ends above a bottom-corner card, $name', (
      tester,
    ) async {
      final ctx = await pumpMini(
        tester,
        location: '/channels/c-general',
        voice: miniCall([remoteShare]),
        size: size,
      );
      await settleMini(tester);

      final card = tester.getRect(player);
      final newest = tester.getRect(find.text(_newest));
      expect(newest.bottom, lessThanOrEqualTo(card.top));
      await ctx.done();
    });
  }

  testWidgets('a card in a top corner leaves the messages where they were', (
    tester,
  ) async {
    final ctx = await pumpMini(
      tester,
      location: '/channels/c-general',
      voice: miniCall([remoteShare]),
      size: desktopSize,
    );
    final low = tester.getRect(find.text(_newest)).bottom;
    ctx.container.read(miniPlayerCornerProvider.notifier).state =
        MiniPlayerCorner.topRight;
    await settleMini(tester);

    expect(tester.getRect(find.text(_newest)).bottom, greaterThan(low));
    await ctx.done();
  });

  testWidgets('a corner the card was dragged to is saved on this device', (
    tester,
  ) async {
    final ctx = await pumpMini(
      tester,
      location: '/channels/c-general',
      voice: miniCall([remoteShare]),
      size: desktopSize,
    );
    final start = tester.getRect(player);
    await tester.timedDragFrom(
      start.center - const Offset(0, 20),
      Offset(-start.left - 40, -start.top - 200),
      const Duration(milliseconds: 300),
    );
    await settleMini(tester);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));

    final prefs = await tester.runAsync(SharedPreferences.getInstance);
    expect(prefs!.getString(miniPlayerCornerKey), 'topLeft');
    await ctx.done();
  });

  testWidgets('a saved corner is where the next call starts', (tester) async {
    final ctx = await pumpMini(
      tester,
      location: '/channels/c-general',
      voice: miniCall([remoteShare]),
      size: desktopSize,
      extraOverrides: [
        preferencesProvider.overrideWith((ref) {
          SharedPreferences.setMockInitialValues({
            miniPlayerCornerKey: 'topLeft',
          });
          return SharedPreferences.getInstance();
        }),
      ],
    );
    await tester.runAsync(() => ctx.container.read(preferencesProvider.future));
    await settleMini(tester);

    final card = tester.getRect(player);
    expect(card.left, lessThan(desktopSize.width / 2));
    expect(card.top, lessThan(desktopSize.height / 2));
    await ctx.done();
  });
}
