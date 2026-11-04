// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The remove button stays on screen and finger-sized at the owner's phone
/// width, whatever the filename or upload state (desktop-vs-mobile rule 2).
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/composer/widgets/composer_attachments.dart';
import 'package:slimm_app/src/features/composer/widgets/staged_attachment_tile.dart';
import 'package:slimm_design_system/design_system.dart';

const _name =
    'a-really-long-holiday-photo-album-export-final-v2-copy-of-copy-2024.jpg';
final _body = AttachmentBody.memory(Uint8List.fromList(const [0]));

final Map<String, StagedAttachment> _states = {
  'uploaded': UploadedAttachment(
    localId: 'a',
    filename: _name,
    body: _body,
    attachment: const api.Attachment(
      id: 's',
      filename: _name,
      contentType: 'image/jpeg',
      size: 1,
    ),
  ),
  'uploading': UploadingAttachment(
    localId: 'a',
    filename: _name,
    body: _body,
    sent: 1,
  ),
  'failed': FailedAttachment(
    localId: 'a',
    filename: _name,
    body: _body,
    message: 'The upload failed because the connection was reset. Try again.',
  ),
};

void main() {
  for (final MapEntry(:key, :value) in _states.entries) {
    testWidgets('the remove button is on screen and 44 tall when $key', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                children: [
                  StagedAttachmentTile(
                    attachment: value,
                    onRemove: () {},
                    onRetry: () {},
                    onToggleSpoiler: () {},
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      final remove = find.bySemanticsLabel('Remove attachment $_name');
      final rect = tester.getRect(remove);
      expect(tester.takeException(), isNull);
      expect(rect.right, lessThanOrEqualTo(390 - 16));
      expect(rect.size, const Size(44, 44));
    });
  }
}
