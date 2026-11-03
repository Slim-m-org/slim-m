// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A module choice setting listing every channel opens the bounded,
/// searchable picker, not one row per channel.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/widgets/admin/module_settings_form.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  testWidgets('20 channel choices open the searchable picker', (tester) async {
    tester.view.physicalSize = const Size(900, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final doc = api.ModuleSettingsDoc.fromJson({
      'settings': [
        {
          'key': 'announce',
          'type': 'choice',
          'label': 'Post level-ups in',
          'value': 'c0',
          'choices': [
            for (var i = 0; i < 20; i++)
              {'value': 'c$i', 'label': '#channel-$i'},
          ],
        },
      ],
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ModuleSettingsForm(doc: doc, onSave: (_) async {}),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Post level-ups in'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byKey(const ValueKey('choice-search')), findsOneWidget);
    final list = find.byKey(const ValueKey('choice-list'));
    expect(tester.getSize(list).height, lessThanOrEqualTo(280));
    expect(find.text('#channel-19'), findsNothing);
  });
}
