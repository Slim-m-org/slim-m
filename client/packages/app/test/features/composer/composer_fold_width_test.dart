// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The message bar answers the width it is given, not the window's: beside a
/// docked member pane on a small desktop window the poll, code and app
/// buttons fold behind the add button so the field keeps room to type in,
/// and with the pane closed they come back (owner, 2026-11-18: "it doesnt
/// seem to consider the member sidebar position").
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/main.dart' show appChromeBuilder;
import 'package:slimm_app/src/features/composer/widgets/composer_field.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../ui_snapshot_support.dart';

final _field = find.byWidgetPredicate((w) => w is ComposerField).first;
final _bar = find.byKey(const Key('composer-action-bar')).first;
final _poll = find.byTooltip('Create a poll');
final _code = find.byTooltip('Insert code');
final _more = find.byTooltip('More actions');

Future<void> _shell(
  WidgetTester tester, {
  required double width,
  required bool members,
  required Future<void> Function() check,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final fixture = await fixtureContainer(
    extraOverrides: [memberPaneVisibleProvider.overrideWith((ref) => members)],
  );
  await withFixtureTeardown(tester, fixture, () async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: fixture.container,
        child: MaterialApp.router(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          routerConfig: fixtureRouter('/channels/c-general'),
          builder: appChromeBuilder,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await check();
  });
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('beside a docked member pane the extras fold behind add', (
    tester,
  ) async {
    await _shell(
      tester,
      width: 836,
      members: true,
      check: () async {
        expect(_poll, findsNothing);
        expect(_code, findsNothing);
        expect(_more, findsOneWidget);
        // The bar's own width less the field is everything on the row beside it.
        final chrome =
            tester.getSize(_bar).width - tester.getSize(_field).width;
        expect(tester.getSize(_field).width, greaterThanOrEqualTo(chrome));
      },
    );
  });

  testWidgets('with the member pane closed they are back on the row', (
    tester,
  ) async {
    await _shell(
      tester,
      width: 836,
      members: false,
      check: () async {
        expect(_poll, findsOneWidget);
        expect(_code, findsOneWidget);
        expect(_more, findsNothing);
        expect(find.byTooltip('Attach a file'), findsOneWidget);
      },
    );
  });

  testWidgets('a wide window keeps every button on the row', (tester) async {
    await _shell(
      tester,
      width: 1440,
      members: true,
      check: () async {
        expect(_poll, findsOneWidget);
        expect(_code, findsOneWidget);
        expect(_more, findsNothing);
      },
    );
  });

  testWidgets('folded, add opens a menu that still reaches each action', (
    tester,
  ) async {
    await _shell(
      tester,
      width: 836,
      members: true,
      check: () async {
        await tester.tap(_more);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.text('Attach a file'), findsOneWidget);
        expect(find.text('Create a poll'), findsOneWidget);
        await tester.tap(find.text('Insert code'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        expect(find.text('Create a poll'), findsNothing, reason: 'closed');
        expect(
          find.text('Code block'),
          findsOneWidget,
          reason: 'the same code picker the row button opens',
        );
      },
    );
  });
}
