// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The channel permissions list: channels under their category headers, one
/// compact row each, with a restricted channel's lock kept on its glyph.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/widgets/admin/channel_permissions_list.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart' as data;
import 'package:slimm_design_system/design_system.dart';

api.Channel _channel(
  String id,
  String name, {
  String? categoryId,
  int position = 0,
  bool restricted = false,
}) => api.Channel(
  id: id,
  name: name,
  kind: 'text',
  createdAt: 0,
  position: position,
  categoryId: categoryId,
  restricted: restricted,
);

Future<data.MessageStore> _store(WidgetTester tester) async {
  final db = data.SlimmDatabase(NativeDatabase.memory());
  final store = data.MessageStore(db);
  await tester.runAsync(() async {
    await store.replaceCategories(const [
      api.ChannelCategory(id: 'k1', name: 'Games', position: 0, createdAt: 0),
    ]);
    await store.replaceChannels([
      _channel('c1', 'general'),
      _channel('c2', 'minecraft', categoryId: 'k1'),
      _channel('c3', 'staff', categoryId: 'k1', position: 1, restricted: true),
    ]);
  });
  return store;
}

void main() {
  testWidgets('groups channels under categories in compact rows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = await _store(tester);
    String? picked;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [storeProvider.overrideWith((ref) async => store)],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: SingleChildScrollView(
              child: ChannelPermissionsList(onPick: (c) => picked = c.id),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Channels'), findsOneWidget);
    expect(find.text('Games'), findsOneWidget);
    final row = find.byKey(const ValueKey('perm-channel-c2'));
    expect(tester.getSize(row).height, lessThan(40));
    expect(
      find.byTooltip('Restricted channel: not visible to everyone'),
      findsOneWidget,
    );

    await tester.tap(row);
    expect(picked, 'c2');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
  });
}
