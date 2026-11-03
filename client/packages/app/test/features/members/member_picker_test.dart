// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The shared member picker: palette people rows, search, keyboard and the
/// result it hands back.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_presence.dart'
    show membersProvider;
import 'package:slimm_app/src/features/members/widgets/member_picker.dart';
import 'package:slimm_design_system/design_system.dart';

api.UserProfile? _picked;

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

Future<void> _pump(
  WidgetTester tester, {
  Size size = const Size(1280, 800),
}) async {
  _picked = null;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final members = [
    for (var i = 0; i < 100; i++)
      api.UserProfile(
        id: 'u$i',
        username: 'user$i',
        displayName: 'Member $i',
        createdAt: 0,
      ),
    const api.UserProfile(
      id: 'ada',
      username: 'lovelace',
      displayName: 'Ada',
      createdAt: 0,
    ),
    const api.UserProfile(
      id: 'bot',
      username: 'helper',
      displayName: 'Helperbot',
      createdAt: 0,
      isBot: true,
    ),
  ];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [membersProvider.overrideWith((ref) async => members)],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                key: const Key('open'),
                onPressed: () async => _picked = await pickMember(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('open')));
  await _settle(tester);
}

void main() {
  testWidgets('typing narrows the list by display name', (tester) async {
    await _pump(tester);

    await tester.enterText(find.byKey(const Key('member-picker-input')), 'ada');
    await _settle(tester);

    expect(find.byKey(const Key('member-picker-row-ada')), findsOneWidget);
    expect(find.byKey(const Key('member-picker-row-u1')), findsNothing);
  });

  testWidgets('a username match says why the row appeared', (tester) async {
    await _pump(tester);

    await tester.enterText(
      find.byKey(const Key('member-picker-input')),
      'lovelace',
    );
    await _settle(tester);

    expect(find.byKey(const Key('member-picker-row-ada')), findsOneWidget);
    expect(find.textContaining('Username: '), findsOneWidget);
  });

  testWidgets('a filter that matches nobody says so', (tester) async {
    await _pump(tester);

    await tester.enterText(
      find.byKey(const Key('member-picker-input')),
      'zzzz',
    );
    await _settle(tester);

    expect(find.text('No members match.'), findsOneWidget);
  });

  testWidgets('bots carry the Bot chip and people do not', (tester) async {
    await _pump(tester);
    await tester.enterText(find.byKey(const Key('member-picker-input')), 'bot');
    await _settle(tester);

    final row = find.byKey(const Key('member-picker-row-bot'));
    expect(
      find.descendant(of: row, matching: find.text('BOT')),
      findsOneWidget,
    );
  });

  testWidgets('arrow keys move the highlight and Enter chooses', (
    tester,
  ) async {
    await _pump(tester);
    await tester.enterText(
      find.byKey(const Key('member-picker-input')),
      'Member 1',
    );
    await _settle(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settle(tester);

    final shown = ['Member 1', 'Member 10', 'Member 11'];
    expect(_picked?.displayName, shown[2]);
  });

  testWidgets('Up from the first row wraps to the last', (tester) async {
    await _pump(tester);
    await tester.enterText(
      find.byKey(const Key('member-picker-input')),
      'Member 9',
    );
    await _settle(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settle(tester);

    expect(_picked?.displayName, 'Member 99');
  });

  testWidgets('tapping a row returns that member', (tester) async {
    await _pump(tester);
    await tester.enterText(find.byKey(const Key('member-picker-input')), 'ada');
    await _settle(tester);

    await tester.tap(find.byKey(const Key('member-picker-row-ada')));
    await _settle(tester);

    expect(_picked?.id, 'ada');
  });

  testWidgets('the list stays inside the window and scrolls to the highlight', (
    tester,
  ) async {
    await _pump(tester, size: const Size(390, 600));
    await tester.tap(find.byKey(const Key('member-picker-input')));

    final list = tester.getSize(find.byKey(const Key('member-picker-list')));
    expect(list.height, lessThanOrEqualTo(600 * 0.6 + 0.01));

    for (var i = 0; i < 20; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    }
    await _settle(tester);
    final listRect = tester.getRect(
      find.byKey(const Key('member-picker-list')),
    );
    final row = tester.getRect(find.byKey(const Key('member-picker-row-u20')));
    expect(listRect.contains(row.center), isTrue);
  });
}
