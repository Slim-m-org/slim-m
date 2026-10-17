// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The uploading tile always shows percent, speed and time left once the rate
/// is stable (owner, 2026-10-16: the hover-only version was never noticed).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_attachments.dart';
import 'package:slimm_app/src/features/composer/widgets/staged_attachment_tile.dart';
import 'package:slimm_app/src/widgets/transfer_meter.dart';
import 'package:slimm_design_system/design_system.dart';

class _Clock {
  DateTime now = DateTime(2026, 10, 15, 12);
}

const _mib = 1024 * 1024;
const _total = 5530 * _mib;

/// An upload that has moved 10 MiB a second for [seconds] seconds.
UploadingAttachment _upload(_Clock clock, int seconds) {
  final meter = TransferMeter(() => clock.now);
  final start = clock.now;
  var sent = 0;
  meter.record(0);
  for (var i = 1; i <= seconds; i++) {
    clock.now = start.add(Duration(seconds: i));
    sent = i * 10 * _mib;
    meter.record(sent);
  }
  return UploadingAttachment(
    localId: 'u1',
    filename: 'Win11.iso',
    body: AttachmentBody.stream(
      length: _total,
      open: () => const Stream.empty(),
    ),
    sent: sent,
    meter: meter,
  );
}

Future<void> _pump(
  WidgetTester tester,
  UploadingAttachment upload,
  Size size,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(
        body: Center(
          child: StagedAttachmentTile(
            attachment: upload,
            onRemove: () {},
            onRetry: () {},
          ),
        ),
      ),
    ),
  );
}

void main() {
  for (final size in const [Size(1200, 800), Size(400, 800)]) {
    testWidgets('a running upload shows percent, speed and time left at '
        '${size.width.toInt()} wide, with no hover', (tester) async {
      await _pump(tester, _upload(_Clock(), 20), size);
      expect(find.text('3% · 10.0 MB/s · 9 min left'), findsOneWidget);
    });
  }

  testWidgets('the first seconds show only progress, no guessed estimate', (
    tester,
  ) async {
    await _pump(tester, _upload(_Clock(), 1), const Size(1200, 800));
    expect(find.text('0% of 5.4 GB'), findsOneWidget);
    expect(find.textContaining('/s'), findsNothing);
  });

  testWidgets('reconnecting hides the estimate', (tester) async {
    final running = _upload(_Clock(), 20);
    await _pump(
      tester,
      UploadingAttachment(
        localId: running.localId,
        filename: running.filename,
        body: running.body,
        sent: running.sent,
        meter: running.meter,
        reconnecting: true,
      ),
      const Size(1200, 800),
    );
    expect(find.text('Reconnecting at 3%…'), findsOneWidget);
    expect(find.textContaining('/s'), findsNothing);
  });
}
