// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The attachment save chip and the reveal tile take Tab and Enter, not only a click.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/downloads/downloads_controller.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_chip.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_reveal.dart';
import 'package:slimm_design_system/design_system.dart';

class _RecordingDownloads extends DownloadsController {
  final started = <String>[];

  @override
  List<DownloadTask> build() => const [];

  @override
  Future<void> start(api.Attachment attachment, {bool original = false}) async {
    started.add(attachment.id);
  }
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  _RecordingDownloads? downloads,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (downloads != null) downloadsProvider.overrideWith(() => downloads),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: Center(child: child)),
      ),
    ),
  );
}

void main() {
  testWidgets('the save chip is reached with Tab and saved with Enter', (
    tester,
  ) async {
    final downloads = _RecordingDownloads();
    await _pump(
      tester,
      const AttachmentChip(
        attachment: api.Attachment(
          id: 'f1',
          filename: 'notes.pdf',
          contentType: 'application/pdf',
          size: 10,
        ),
      ),
      downloads: downloads,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(downloads.started, ['f1']);
  });

  testWidgets('the reveal tile is reached with Tab and revealed with Enter', (
    tester,
  ) async {
    var revealed = 0;
    await _pump(
      tester,
      AttachmentRevealTile(
        caption: 'clip.gif',
        onReveal: () => revealed++,
        maxEdge: 200,
        icon: AppIcons.play,
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(revealed, 1);
  });
}
