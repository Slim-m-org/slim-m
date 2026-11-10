// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An upload's progress repaints its own tile only: the staging and the whole
/// composer hear about a pick, a retry, a removal or an outcome, never a chunk.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/composer/widgets/composer.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_attachments.dart';

import 'composer_harness.dart';

const _done = api.Attachment(
  id: 'a1',
  filename: 'big.iso',
  contentType: 'application/octet-stream',
  size: 100,
);

AttachmentBody _body() =>
    AttachmentBody.stream(length: 100, open: () => const Stream.empty());

class _Upload {
  final gate = Completer<api.Attachment>();
  late UploadReport report;

  Future<api.Attachment> call(AttachmentBody _, String _, UploadReport r) {
    report = r;
    return gate.future;
  }
}

void main() {
  test('a chunk moves the item\'s progress and notifies nobody else', () async {
    final upload = _Upload();
    final staging = AttachmentStagingController(upload: upload.call);
    addTearDown(staging.dispose);
    var heard = 0;
    staging.addListener(() => heard += 1);

    await staging.stageBody(_body(), 'big.iso');
    final item = staging.items.single as UploadingAttachment;
    final seen = <UploadProgress>[];
    item.progress.addListener(() => seen.add(item.progress.value));

    upload
      ..report(10)
      ..report(20)
      ..report.onRetrying(true);

    expect(heard, 1, reason: 'only the pick itself is a staging change');
    expect(seen, [
      (sent: 10, reconnecting: false),
      (sent: 20, reconnecting: false),
      (sent: 20, reconnecting: true),
    ]);
    expect(item.fraction, 0.2);
    expect(staging.items.single, same(item));

    upload.gate.complete(_done);
    await Future<void>.delayed(Duration.zero);
    expect(heard, 2, reason: 'the outcome is a staging change');
    expect(staging.items.single, isA<UploadedAttachment>());
  });

  test('a chunk that lands after its tile was removed is dropped', () async {
    final upload = _Upload();
    final staging = AttachmentStagingController(upload: upload.call);
    addTearDown(staging.dispose);

    await staging.stageBody(_body(), 'big.iso');
    final item = staging.items.single as UploadingAttachment;
    staging.remove(item.localId);

    upload.report(50);

    expect(item.sent, 0);
  });

  test('a retried upload reports on its own fresh progress', () async {
    var attempts = 0;
    late UploadReport report;
    final staging = AttachmentStagingController(
      upload: (_, _, r) async {
        report = r;
        if (++attempts == 1) throw const api.ServerException('full', 507);
        return _done;
      },
    );
    addTearDown(staging.dispose);
    await staging.stageBody(_body(), 'big.iso');
    await Future<void>.delayed(Duration.zero);
    final failed = staging.items.single;
    expect(failed, isA<FailedAttachment>());

    staging.retry(failed.localId);
    final retried = staging.items.single as UploadingAttachment;
    report(30);

    expect(retried.sent, 30);
  });

  testWidgets('streaming progress rebuilds the tile and not the composer', (
    tester,
  ) async {
    final upload = _Upload();
    final staging = AttachmentStagingController(upload: upload.call);
    addTearDown(staging.dispose);
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: Sends(),
        platform: TargetPlatform.linux,
        extraOverrides: [
          attachmentStagingProvider.overrideWith((ref, id) => staging),
        ],
      ),
    );
    await staging.stageBody(_body(), 'big.iso');
    await tester.pump();
    expect(find.text('0% of 100 B'), findsOneWidget);

    var composerBuilds = 0;
    debugOnRebuildDirtyWidget = (element, _) {
      if (element.widget is Composer) composerBuilds += 1;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    for (var sent = 10; sent <= 50; sent += 10) {
      upload.report(sent);
      await tester.pump();
    }

    expect(find.text('50% of 100 B'), findsOneWidget);
    expect(composerBuilds, 0);

    upload.gate.complete(_done);
    await tester.pump();
    expect(find.textContaining('% of 100 B'), findsNothing);
    expect(composerBuilds, greaterThan(0), reason: 'the outcome does rebuild');
  });
}
