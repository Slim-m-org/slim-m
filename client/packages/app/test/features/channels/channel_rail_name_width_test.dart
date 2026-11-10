// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The manage kebab is revealed on hover, so while it is hidden a managed
/// row's name runs to the same edge as an unmanaged one. A reserved slot
/// truncated every name in the rail about 40 px early for managers.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/widgets/channel_rail_sections.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/fake_api.dart';

const _longName = 'book-recommendations-and-reading-lists';

Channel _channel(String id, String name, {String kind = 'text'}) => Channel(
  id: id,
  name: name,
  kind: kind,
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
);

Future<void> _pumpRail(
  WidgetTester tester, {
  required bool canManage,
  String kind = 'text',
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWithValue(
          api.SessionStore(
            tokens: const api.TokenPair(
              userId: 'u-me',
              accessToken: 'access',
              refreshToken: 'refresh',
              accessExpiresAt: 4102444800000,
            ),
          ),
        ),
        mockApiOverride((_) async => http.Response('', 404)),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 240,
              child: ChannelCategorySections(
                channels: [_channel('c1', _longName, kind: kind)],
                categories: const [],
                selectedId: null,
                canManage: canManage,
                onReorder: (_) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Rect _nameRect(WidgetTester tester) => tester.getRect(find.text(_longName));

final _row = find.bySemanticsLabel(RegExp('^$_longName'));

void main() {
  for (final kind in ['text', 'voice']) {
    testWidgets('a $kind row a manager sees gives its name the full width '
        'while the kebab is hidden', (tester) async {
      await _pumpRail(tester, canManage: false, kind: kind);
      final plain = _nameRect(tester);

      await _pumpRail(tester, canManage: true, kind: kind);
      expect(
        _nameRect(tester).right,
        plain.right,
        reason: 'a hidden kebab must not hold a slot that truncates the name',
      );
    });
  }

  testWidgets('hovering reveals the kebab at the row end and narrows only '
      'the name, never the row', (tester) async {
    await _pumpRail(tester, canManage: true);
    final kebab = find.byIcon(AppIcons.moreVertical);
    final nameBefore = _nameRect(tester);
    final kebabBefore = tester.getRect(kebab);
    final rowBefore = tester.getRect(_row);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    await tester.pump();
    await gesture.moveTo(nameBefore.center);
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.getRect(kebab), kebabBefore);
    expect(tester.getRect(_row), rowBefore);
    expect(
      _nameRect(tester).right,
      lessThanOrEqualTo(kebabBefore.left),
      reason: 'a revealed kebab must never paint over the name',
    );
    await gesture.removePointer();
  });
}
