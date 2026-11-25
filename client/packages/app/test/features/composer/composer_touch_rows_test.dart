// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The suggestion rows and the bot help card meet the touch target on a phone.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/composer/widgets/composer_autocomplete.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_autocomplete_items.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_bot_mention_help.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(WidgetTester tester, double width, Widget body) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(body: body),
    ),
  );
}

void main() {
  Widget list() => ComposerAutocomplete(
    suggestions: const [
      AutocompleteSuggestion(insert: '!a ', label: '!a'),
      AutocompleteSuggestion(insert: '!b ', label: '!b'),
    ],
    selected: 0,
    onPick: (_) {},
    onHover: (_) {},
  );

  testWidgets('suggestion rows are 44 tall on a phone', (tester) async {
    await _pump(tester, 390, list());
    final row = find.ancestor(
      of: find.text('!a'),
      matching: find.byWidgetPredicate((w) => w is Container),
    );
    expect(tester.getSize(row.first).height, AppSizes.rowTouch);
  });

  testWidgets('suggestion rows keep the compact height on desktop', (
    tester,
  ) async {
    await _pump(tester, 1280, list());
    final row = find.ancestor(
      of: find.text('!a'),
      matching: find.byWidgetPredicate((w) => w is Container),
    );
    expect(tester.getSize(row.first).height, AppSizes.controlMd);
  });

  testWidgets('the bot help dismiss is a labelled touch target', (
    tester,
  ) async {
    var dismissed = 0;
    await _pump(
      tester,
      390,
      ComposerBotMentionHelp(
        commands: const [
          api.ChannelBotCommand(
            botUserId: 'b',
            botUsername: 'bot',
            botDisplayName: 'Bot',
            prefix: '!',
            name: 'play',
            description: 'Plays',
          ),
        ],
        onDismiss: () => dismissed++,
      ),
    );
    final dismiss = find.byWidgetPredicate(
      (w) => w is AppIconButton && w.semanticLabel == 'Dismiss bot help',
    );
    expect(dismiss, findsOneWidget);
    expect(
      tester
          .getSize(find.byWidgetPredicate((w) => w is AppIconButton))
          .shortestSide,
      greaterThanOrEqualTo(AppSizes.rowTouch),
    );
    await tester.tap(dismiss);
    expect(dismissed, 1);
  });
}
