// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The full release history under Settings, About: every shipped entry shows
/// its version, the latest is open and older ones fold.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/whats_new/whats_new_content.dart';
import 'package:slimm_app/src/widgets/release_notes_entry.dart';
import 'package:slimm_app/src/widgets/whats_new_sheet.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _open(
  WidgetTester tester,
  Future<void> Function(BuildContext) opener,
) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => opener(context),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('release notes lists every entry with its version', (
    tester,
  ) async {
    await _open(tester, showReleaseNotesSheet);

    final shown = tester
        .widgetList<ReleaseNotesHeading>(find.byType(ReleaseNotesHeading))
        .map((h) => h.entry.version)
        .toList();
    expect(shown, whatsNewEntries.reversed.map((e) => e.version).toList());
    for (final entry in whatsNewEntries) {
      expect(find.text(entry.version, skipOffstage: false), findsOneWidget);
    }
  });

  testWidgets('only the latest entry starts open and a tap folds it', (
    tester,
  ) async {
    await _open(tester, showReleaseNotesSheet);

    expect(find.byType(ReleaseNotesPoints), findsOneWidget);
    await tester.tap(find.text(whatsNewEntries.last.headline));
    await tester.pumpAndSettle();
    expect(find.byType(ReleaseNotesPoints), findsNothing);
  });

  testWidgets('the what\'s new sheet shows each unseen version', (
    tester,
  ) async {
    await _open(
      tester,
      (context) => showWhatsNewSheet(
        context,
        whatsNewEntries.sublist(whatsNewEntries.length - 2),
      ),
    );

    for (final entry in whatsNewEntries.sublist(whatsNewEntries.length - 2)) {
      expect(find.text(entry.version, skipOffstage: false), findsOneWidget);
    }
    expect(
      find.byType(ReleaseNotesPoints, skipOffstage: false),
      findsNWidgets(2),
    );
  });
}
