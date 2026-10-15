// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The uploading tile's speed and time left (owner, 2026-10-15): only past
/// ten seconds, on hover where there is a pointer, always on a narrow layout.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/composer_attachments.dart';
import 'package:slimm_app/src/widgets/staged_attachment_tile.dart';
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

Future<void> _hover(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  await mouse.moveTo(tester.getCenter(find.byType(LinearProgressIndicator)));
  await tester.pump();
}

void main() {
  testWidgets(
    'on a wide layout, hovering a long upload swaps in speed and time left',
    (tester) async {
      await _pump(tester, _upload(_Clock(), 20), const Size(1200, 800));
      expect(find.text('3% of 5.4 GB'), findsOneWidget);
      await _hover(tester);
      expect(find.text('10.0 MB/s · about 9 min left'), findsOneWidget);
    },
  );

  testWidgets('a short upload shows only its progress, even hovered', (
    tester,
  ) async {
    await _pump(tester, _upload(_Clock(), 5), const Size(1200, 800));
    await _hover(tester);
    expect(find.textContaining('/s'), findsNothing);
    expect(find.textContaining('left'), findsNothing);
  });

  testWidgets(
    'on a narrow layout a long upload shows time left without a hover',
    (tester) async {
      await _pump(tester, _upload(_Clock(), 20), const Size(400, 800));
      expect(find.text('3% · about 9 min left'), findsOneWidget);
    },
  );
}
