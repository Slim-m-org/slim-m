// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A section header's `+` used to be always visible, on the theory that "a
/// header has no hover state of its own". It does now, the same
/// `MouseRegion` pattern `ManagedChannelRow` already uses for its kebab.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_sections.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'u-me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 4102444800000,
);

ChannelCategoryRow _category() =>
    const ChannelCategoryRow(id: 'cat1', name: 'Lounge', position: 0);

Channel _channel() => const Channel(
  id: 'c1',
  name: 'general',
  kind: 'text',
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
  categoryId: 'cat1',
);

Future<void> _pump(WidgetTester tester, {double width = 1200}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((_) async => http.Response('', 404)),
        );
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: ChannelCategorySections(
            channels: [_channel()],
            categories: [_category()],
            selectedId: null,
            canManage: true,
            onReorder: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

AnimatedOpacity _glyphOpacityWidget(WidgetTester tester) =>
    tester.widget<AnimatedOpacity>(
      find.ancestor(
        of: find.byIcon(AppIcons.add),
        matching: find.byType(AnimatedOpacity),
      ),
    );

void main() {
  testWidgets(
    'on a pointer layout, the add glyph starts hidden and reveals on hover',
    (tester) async {
      await _pump(tester);

      expect(_glyphOpacityWidget(tester).opacity, 0);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.text('Lounge')));
      await tester.pump();

      expect(_glyphOpacityWidget(tester).opacity, 1);

      // Below the two rendered rows, clear of every MouseRegion in the tree.
      await gesture.moveTo(const Offset(600, 750));
      await tester.pump();
      expect(_glyphOpacityWidget(tester).opacity, 0);

      await gesture.removePointer();
    },
  );

  testWidgets('on a touch layout, the add glyph is always shown', (
    tester,
  ) async {
    await _pump(tester, width: 390);

    expect(_glyphOpacityWidget(tester).opacity, 1);
  });
}
