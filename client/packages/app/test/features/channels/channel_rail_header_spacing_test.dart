// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Category headers in the desktop rail sit one pointer row apart plus a
/// small lead. The add button, hidden until hover, once set every header's
/// height to its own, so stacked categories stood 44 px apart for a manager.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/collapsed_categories_preference.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_sections.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

Channel _channel(String id, String category, int position) => Channel(
  id: id,
  name: id,
  kind: 'text',
  createdAt: 0,
  position: position,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
  categoryId: category,
);

Future<void> _pumpRail(WidgetTester tester, {required bool canManage}) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({
    collapsedCategoriesKey: ['dev'],
  });
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(
        api.SessionStore(
          tokens: const api.TokenPair(
            userId: 'self',
            accessToken: 'access',
            refreshToken: 'refresh',
            accessExpiresAt: 0,
          ),
        ),
      ),
      preferencesProvider.overrideWith(
        (ref) => SharedPreferences.getInstance(),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 240,
              child: ChannelCategorySections(
                channels: [
                  _channel('chat', 'general', 0),
                  _channel('dev-notes', 'dev', 0),
                  _channel('jellyfin', 'media', 0),
                ],
                categories: const [
                  ChannelCategoryRow(
                    id: 'general',
                    name: 'general',
                    position: 0,
                  ),
                  ChannelCategoryRow(id: 'dev', name: 'dev', position: 1),
                  ChannelCategoryRow(id: 'media', name: 'media', position: 2),
                ],
                selectedId: 'chat',
                canManage: canManage,
                onReorder: (_) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

double _top(WidgetTester tester, String text) =>
    tester.getRect(find.text(text)).top;

void main() {
  testWidgets('a collapsed category and the next sit one header apart', (
    tester,
  ) async {
    await _pumpRail(tester, canManage: true);
    expect(
      _top(tester, 'media') - _top(tester, 'dev'),
      AppSpacing.s4 + AppSizes.rowPointer,
    );
  });

  testWidgets('a header is placed the same with or without the add button', (
    tester,
  ) async {
    await _pumpRail(tester, canManage: false);
    final plain = [
      for (final t in ['dev', 'media', 'jellyfin']) _top(tester, t),
    ];
    await _pumpRail(tester, canManage: true);
    final managed = [
      for (final t in ['dev', 'media', 'jellyfin']) _top(tester, t),
    ];
    expect(managed, plain);
    // Lets the first rail's debounces run out once both trees are gone.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets(
    'a header sits closer to its own channels than to the ones above',
    (tester) async {
      await _pumpRail(tester, canManage: true);
      final above =
          _top(tester, 'dev') - tester.getRect(find.text('chat')).bottom;
      final below =
          _top(tester, 'jellyfin') - tester.getRect(find.text('media')).bottom;
      expect(below, lessThan(above));
    },
  );
}
