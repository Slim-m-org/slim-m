// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The shell's panes show a background picture through themselves, while a
/// drawer that floats over them stays opaque.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/background/providers/app_background_controller.dart';
import 'package:slimm_app/src/features/background/providers/background_image_store.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../settings/home_shell_harness.dart';

Future<({ProviderContainer container, SlimmDatabase db})> _shell(
  WidgetTester tester,
  double width,
) async {
  SharedPreferences.setMockInitialValues({});
  final store = MemoryBackgroundImageStore();
  final s = setup(
    httpClient: quietClient(),
    signedIn: true,
    extraOverrides: [
      backgroundImageStoreProvider.overrideWithValue(store),
      appBackgroundControllerProvider.overrideWith(
        () => AppBackgroundController(
          const AppBackgroundSettings(hasImage: true),
        ),
      ),
    ],
  );
  await MessageStore(s.db).upsertChannels([
    const api.Channel(id: 'c2', name: 'general', kind: 'text', createdAt: 0),
  ]);
  await tester.runAsync(() async {
    await store.write(
      File('test/fixtures/background_forest.png').readAsBytesSync(),
    );
    await s.container.read(backgroundPictureProvider.future);
  });
  await pumpAtWidth(tester, s.container, width, location: '/channels/c2');
  return (container: s.container, db: s.db);
}

void main() {
  testWidgets('the docked rail lets the picture through', (tester) async {
    final s = await _shell(tester, 1400);
    await tester.pump();
    final surface = find.byKey(ChannelRail.surfaceKey);
    expect(AppBackgroundScope.showingOf(tester.element(surface)), isTrue);
    final rail = tester.widget<Container>(surface);
    expect((rail.color ?? Colors.black).a, closeTo(kBackgroundPaneAlpha, 0.01));
    expect(find.byKey(const Key('app_background_layer')), findsOneWidget);
    await teardown(tester, s.container, s.db);
  });

  testWidgets('the phone rail drawer stays opaque over the chat', (
    tester,
  ) async {
    final s = await _shell(tester, 500);
    await tester.pump();
    final withDrawer = find.byWidgetPredicate(
      (w) => w is Scaffold && w.drawer != null,
    );
    final scaffold = tester.widget<Scaffold>(withDrawer);
    expect(scaffold.backgroundColor, Colors.transparent);
    tester.state<ScaffoldState>(withDrawer).openDrawer();
    await tester.pump();
    // The drawer's slide is a fixed-length route animation; one pump past it is enough.
    await tester.pump(const Duration(seconds: 1));
    final surface = find.byKey(ChannelRail.surfaceKey);
    expect(AppBackgroundScope.showingOf(tester.element(surface)), isFalse);
    await teardown(tester, s.container, s.db);
  });
}
