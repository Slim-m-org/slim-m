// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The picker copies are deleted once nothing stages or uploads them, and
/// never while a file is still being read.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/composer/widgets/composer_attachment_tray.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_attachments.dart';
import 'package:slimm_app/src/features/composer/widgets/picker_temp_files.dart';

import 'composer_harness.dart' show MemoryFile;

api.Attachment _attachment() => const api.Attachment(
  id: 'a1',
  filename: 'clip.mp4',
  contentType: 'video/mp4',
  size: 4,
);

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late int clears;
  late PickerTempFiles tempFiles;
  late Completer<api.Attachment> gate;
  late AttachmentStagingController controller;

  setUp(() {
    clears = 0;
    tempFiles = PickerTempFiles(() async => clears += 1);
    gate = Completer<api.Attachment>();
    controller = AttachmentStagingController(
      upload: (_, _, _) => gate.future,
      tempFiles: tempFiles,
    );
  });
  tearDown(() => controller.dispose());

  MemoryFile clip({int? length}) =>
      MemoryFile('clip.mp4', Uint8List.fromList([1, 2, 3, 4]), length: length);

  test('nothing is cleared while an upload still reads its file', () async {
    await controller.stageFile(clip().source);
    await _settle();

    expect(clears, 0);
    expect(controller.items.single, isA<UploadingAttachment>());
  });

  test('a finished upload clears the copy', () async {
    await controller.stageFile(clip().source);
    gate.complete(_attachment());
    await _settle();

    expect(controller.items.single, isA<UploadedAttachment>());
    expect(clears, 1);
  });

  test('a failed upload keeps its copy for the retry', () async {
    await controller.stageFile(clip().source);
    gate.completeError(const api.ServerException('no space left', 507));
    await _settle();

    expect(controller.items.single, isA<FailedAttachment>());
    expect(clears, 0);

    controller.remove(controller.items.single.localId);
    expect(clears, 1);
  });

  test('removing an upload in flight clears the copy', () async {
    await controller.stageFile(clip().source);
    controller.remove(controller.items.single.localId);

    expect(clears, 1);
  });

  test('a refused pick clears its copy', () async {
    final limited = AttachmentStagingController(
      upload: (_, _, _) => gate.future,
      maxBytes: () async => 2,
      tempFiles: tempFiles,
    );
    addTearDown(limited.dispose);

    await limited.stageFile(clip().source);

    expect(limited.items, isEmpty);
    expect(clears, 1);
  });

  test('one list finishing waits for another still uploading', () async {
    final other = AttachmentStagingController(
      upload: (_, _, _) => Completer<api.Attachment>().future,
      tempFiles: tempFiles,
    );
    addTearDown(other.dispose);

    await other.stageFile(clip().source);
    await controller.stageFile(clip().source);
    gate.complete(_attachment());
    await _settle();

    expect(clears, 0, reason: 'the other list still reads its file');

    other.clear();
    expect(clears, 1);
  });

  test('sending the uploaded files clears nothing still in use', () async {
    await controller.stageFile(clip().source);
    gate.complete(_attachment());
    await _settle();
    final before = clears;

    await controller.sendReady((_) async {});

    expect(controller.items, isEmpty);
    expect(clears, greaterThan(before));
  });

  test('a large upload on a phone asks to keep the app open', () async {
    await controller.stageFile(
      clip(length: kInMemoryAttachmentBytes + 1).source,
    );

    expect(
      attachmentSendBlockReason(controller, onPhone: true),
      'Send waits for the upload to finish. Keep slim-m open until then.',
    );
    expect(
      attachmentSendBlockReason(controller),
      'Send waits for the upload to finish.',
    );
  });

  test('a small upload does not ask to keep the app open', () async {
    await controller.stageFile(clip().source);

    expect(
      attachmentSendBlockReason(controller, onPhone: true),
      'Send waits for the upload to finish.',
    );
  });
}
