// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Settings scrolled to the bottom under a home-indicator inset, and staged
/// attachment tiles at phone and desktop width. Written only under
/// SLIMM_UI_SNAPSHOTS=1.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/composer/widgets/composer_attachments.dart';
import 'package:slimm_app/src/features/composer/widgets/staged_attachment_tile.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_panes.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../ui_snapshot_support.dart';

const _name = 'a-really-long-holiday-photo-album-export-final-v2-copy.jpg';

Future<void> _pump(WidgetTester tester, Size size, Widget home) async {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  tester.view.padding = const FakeViewPadding(top: 59 * 3, bottom: 34 * 3);
  tester.view.viewPadding = const FakeViewPadding(top: 59 * 3, bottom: 34 * 3);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    RepaintBoundary(
      key: snapshotBoundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: home,
      ),
    ),
  );
  await tester.pump(const Duration(seconds: 1));
}

void _scrollToEnd(WidgetTester tester, {double back = 0}) {
  final position = tester
      .state<ScrollableState>(
        find.byWidgetPredicate((w) => w is Scrollable).first,
      )
      .position;
  position.jumpTo(position.maxScrollExtent - back);
}

Widget _panes({String? open}) => SettingsPanesScaffold(
  title: 'Settings',
  backTooltip: 'Back',
  backFallback: '/',
  initialPaneId: open,
  groups: [
    for (var g = 0; g < 3; g++)
      SettingsPaneGroup(
        label: 'Group $g',
        panes: [
          for (var i = 0; i < 5; i++)
            SettingsPane(
              id: 'p$g$i',
              label: 'Pane $g.$i',
              builder: (_) => Column(
                children: [
                  for (var r = 0; r < 24; r++) ListTile(title: Text('Row $r')),
                ],
              ),
            ),
        ],
      ),
  ],
);

Widget _tiles() {
  final body = AttachmentBody.memory(Uint8List.fromList(const [0]));
  return Scaffold(
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children:
            [
                  UploadedAttachment(
                    localId: 'a',
                    filename: _name,
                    body: body,
                    attachment: const api.Attachment(
                      id: 's',
                      filename: _name,
                      contentType: 'image/jpeg',
                      size: 1,
                    ),
                  ),
                  UploadingAttachment(
                    localId: 'b',
                    filename: _name,
                    body: body,
                    sent: 1,
                  ),
                  FailedAttachment(
                    localId: 'c',
                    filename: _name,
                    body: body,
                    message:
                        'The upload failed because the connection was reset.',
                  ),
                ]
                .map(
                  (a) => StagedAttachmentTile(
                    attachment: a,
                    onRemove: () {},
                    onRetry: () {},
                    onToggleSpoiler: () {},
                  ),
                )
                .toList(),
      ),
    ),
  );
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('settings top level scrolled to the bottom', (tester) async {
    await _pump(tester, const Size(390, 844), _panes());
    _scrollToEnd(tester);
    await tester.pump();
    await writeSnapshot(tester, 'phone-inset-settings-bottom');
  });

  testWidgets('settings top level a little above the bottom', (tester) async {
    await _pump(tester, const Size(390, 844), _panes());
    _scrollToEnd(tester, back: 60);
    await tester.pump();
    await writeSnapshot(tester, 'phone-inset-settings-near-bottom');
  });

  testWidgets('a settings pane scrolled to the bottom', (tester) async {
    await _pump(tester, const Size(390, 844), _panes(open: 'p00'));
    _scrollToEnd(tester);
    await tester.pump();
    await writeSnapshot(tester, 'phone-inset-pane-bottom');
  });

  for (final (label, size) in [
    ('phone', const Size(390, 600)),
    ('desktop', const Size(900, 400)),
  ]) {
    testWidgets('staged attachments at $label', (tester) async {
      await _pump(tester, size, _tiles());
      await writeSnapshot(tester, 'staged-attachments-$label');
      expect(tester.takeException(), isNull);
    });
  }
}
