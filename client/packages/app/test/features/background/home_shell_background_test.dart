// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The shell's panes show a background picture through themselves, while a
/// drawer that floats over them stays opaque.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
    final context = tester.element(find.byType(ChannelRail));
    expect(AppBackgroundScope.showingOf(context), isTrue);
    final rail = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(ChannelRail),
            matching: find.byType(Container),
          )
          .first,
    );
    expect((rail.color ?? Colors.black).a, closeTo(kBackgroundPaneAlpha, 0.01));
    expect(find.byKey(const Key('app_background_layer')), findsOneWidget);
    await teardown(tester, s.container, s.db);
  });

  testWidgets('the phone rail drawer stays opaque over the chat', (
    tester,
  ) async {
    final s = await _shell(tester, 500);
    await tester.pump();
    final scaffold = tester
        .widgetList<Scaffold>(find.byType(Scaffold))
        .firstWhere((w) => w.drawer != null);
    expect(scaffold.backgroundColor, Colors.transparent);
    final state = tester.state<ScaffoldState>(find.byWidget(scaffold));
    state.openDrawer();
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(ChannelRail));
    expect(AppBackgroundScope.showingOf(context), isFalse);
    await teardown(tester, s.container, s.db);
  });
}
