// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A `@username` mention reads as the member's name in this space.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/messages/widgets/message_text.dart';
import 'package:slimm_design_system/design_system.dart';

api.UserProfile _member(String username, String shown) => api.UserProfile(
  id: username,
  username: username,
  displayName: shown,
  createdAt: 0,
);

Widget _body(String content, List<api.UserProfile> members) => ProviderScope(
  overrides: [membersProvider.overrideWith((ref) async => members)],
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(
      body: MessageBody(
        content: content,
        knownUsernames: {for (final m in members) m.username},
      ),
    ),
  ),
);

Future<void> _hover(WidgetTester tester, Finder target) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  await mouse.moveTo(tester.getCenter(target));
  await tester.pump(const Duration(seconds: 2));
}

void main() {
  testWidgets('a nicknamed member shows the nickname and hovers the username', (
    tester,
  ) async {
    await tester.pumpWidget(
      _body('hi @alice', [_member('alice', 'Captain Al')]),
    );
    await tester.pump();

    expect(find.text('@Captain Al'), findsOneWidget);
    expect(find.text('@alice'), findsNothing);
    await _hover(tester, find.text('@Captain Al'));
    expect(find.text('@alice'), findsOneWidget);
  });

  testWidgets('two members with one name are told apart by the hover', (
    tester,
  ) async {
    await tester.pumpWidget(
      _body('@ann and @bob', [_member('ann', 'Sam'), _member('bob', 'Sam')]),
    );
    await tester.pump();

    expect(find.text('@Sam'), findsNWidgets(2));
    await _hover(tester, find.text('@Sam').first);
    expect(find.text('@ann'), findsOneWidget);
    expect(find.text('@bob'), findsNothing);
  });

  testWidgets('unknown names, reserved words and code stay as written', (
    tester,
  ) async {
    await tester.pumpWidget(
      _body('@ghost @everyone `@alice`', [_member('alice', 'Captain Al')]),
    );
    await tester.pump();

    expect(find.textContaining('@ghost'), findsOneWidget);
    expect(find.text('@everyone'), findsOneWidget);
    expect(find.text('@Captain Al'), findsNothing);
  });
}
