// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Unit tests for [AttachmentStagingController], the piece the composer's
/// visible-attachment fix actually rests on, independent of any widget pump
/// timing.
///
/// The owner's report was that a picked file vanished until its upload
/// finished; these drive the controller directly with a [Completer] the
/// test holds open, so "visible before the upload resolves" is asserted
/// while it is still unresolved rather than raced against a fake network.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/composer_attachments.dart';

api.Attachment _attachment({
  String id = 'a1',
  String filename = 'holiday.png',
}) => api.Attachment(
  id: id,
  filename: filename,
  contentType: 'image/png',
  size: 4,
);

void main() {
  final bytes = Uint8List.fromList([1, 2, 3, 4]);

  test('a stage is visible before its upload resolves', () async {
    final gate = Completer<api.Attachment>();
    final controller = AttachmentStagingController(
      upload: (_, _, _) => gate.future,
    );

    final staged = controller.stage(bytes, 'holiday.png');
    // Checked before `staged` or the gate ever resolves, or the reported bug is back.
    expect(controller.items, hasLength(1));
    expect(controller.items.single, isA<UploadingAttachment>());
    expect(controller.hasBlockingAttachment, isTrue);
    expect(controller.readyIds, isEmpty);

    gate.complete(_attachment());
    await staged;
    await Future<void>.delayed(Duration.zero);

    expect(controller.items.single, isA<UploadedAttachment>());
    expect(controller.readyIds, ['a1']);
    expect(controller.hasBlockingAttachment, isFalse);
  });

  test('a failed upload stays staged, visibly, until retried', () async {
    var attempts = 0;
    final controller = AttachmentStagingController(
      upload: (_, _, _) async {
        attempts += 1;
        if (attempts == 1) {
          throw const api.ServerException('no space left', 507);
        }
        return _attachment();
      },
    );

    await controller.stage(bytes, 'holiday.png');
    await Future<void>.delayed(Duration.zero);

    expect(controller.items.single, isA<FailedAttachment>());
    expect(controller.hasBlockingAttachment, isTrue);
    expect(controller.readyIds, isEmpty);

    final localId = controller.items.single.localId;
    controller.retry(localId);
    expect(
      controller.items.single,
      isA<UploadingAttachment>(),
      reason: 'a retry is visible immediately too, the same as a first pick',
    );

    await Future<void>.delayed(Duration.zero);

    expect(controller.items.single, isA<UploadedAttachment>());
    expect(controller.readyIds, ['a1']);
    expect(attempts, 2);
  });

  test('removing a staged attachment drops it, even mid-upload', () async {
    final gate = Completer<api.Attachment>();
    final controller = AttachmentStagingController(
      upload: (_, _, _) => gate.future,
    );

    unawaited(controller.stage(bytes, 'holiday.png'));
    final localId = controller.items.single.localId;
    controller.remove(localId);
    expect(controller.items, isEmpty);

    gate.complete(_attachment());
    await Future<void>.delayed(Duration.zero);

    expect(
      controller.items,
      isEmpty,
      reason:
          'a removed attachment must not reappear once its upload '
          'finally answers',
    );
  });

  test(
    'addResolved stages an already-uploaded attachment with no upload call',
    () async {
      var uploadCalls = 0;
      final controller = AttachmentStagingController(
        upload: (_, _, _) async {
          uploadCalls += 1;
          return _attachment();
        },
      );

      controller.addResolved(
        _attachment(id: 'gif-1', filename: 'gif.gif'),
        bytes,
      );

      expect(controller.items.single, isA<UploadedAttachment>());
      expect(controller.readyIds, ['gif-1']);
      expect(controller.hasBlockingAttachment, isFalse);
      expect(
        uploadCalls,
        0,
        reason:
            'the picker already stored it server-side; nothing here '
            'should re-upload it',
      );
    },
  );

  test('looksLikeImage matches by extension only', () {
    expect(looksLikeImage('photo.png'), isTrue);
    expect(looksLikeImage('photo.JPG'), isTrue);
    expect(looksLikeImage('notes.txt'), isFalse);
    expect(looksLikeImage('noextension'), isFalse);
  });

  test(
    'a different account signing in empties every channel\'s staging',
    () async {
      const bob = api.TokenPair(
        userId: 'bob',
        accessToken: 'a',
        refreshToken: 'r',
        accessExpiresAt: 0,
      );
      final session = api.SessionStore(tokens: bob);
      final container = ProviderContainer(
        overrides: [sessionProvider.overrideWithValue(session)],
      );
      addTearDown(container.dispose);
      container
          .read(attachmentStagingProvider('c1'))
          .addResolved(
            const api.Attachment(
              id: 'a1',
              filename: 'photo.png',
              contentType: 'image/png',
              size: 1,
            ),
            Uint8List.fromList(const [1]),
          );
      expect(container.read(attachmentStagingProvider('c1')).isEmpty, isFalse);

      session.set(
        const api.TokenPair(
          userId: 'alice',
          accessToken: 'a',
          refreshToken: 'r',
          accessExpiresAt: 0,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        container.read(attachmentStagingProvider('c1')).isEmpty,
        isTrue,
        reason:
            'the next account on this device must never see the last one\'s files',
      );
    },
  );
}
