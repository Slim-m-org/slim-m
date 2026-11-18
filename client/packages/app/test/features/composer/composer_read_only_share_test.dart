// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A channel without Send mounts no composer, so nothing can be staged into
/// one nobody sees: a share handed to it is refused where the composer would be.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/features/channels/screens/channel_composer_area.dart';
import 'package:slimm_app/src/features/composer/providers/composer_attachment_drop.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_attachments.dart';
import 'package:slimm_app/src/features/share/providers/incoming_share.dart';
import 'package:slimm_app/src/permissions.dart';

import '../../channel_history_harness.dart';

void main() {
  testWidgets('a share handed to a read-only channel is refused inline', (
    tester,
  ) async {
    final harness = await mountChannel(
      tester,
      serverSeqs: const [1],
      seededSeqs: const [1],
      answerFirst: (request) async =>
          request.url.path == '/channels/c1/permissions'
          ? http.Response(
              jsonEncode({'permissions': Perm.viewChannel}),
              200,
              headers: {'content-type': 'application/json'},
            )
          : null,
    );
    final dir = Directory.systemTemp.createTempSync('read-only-share-test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/a.png';
    File(path).writeAsBytesSync(Uint8List(4));
    final container = harness.container;
    expect(container.read(composerAttachmentDropProvider('c1')), isNull);

    container.read(shareHandoffProvider.notifier).state = (
      channelId: 'c1',
      share: IncomingShare(
        files: [SharedFile(path: path, name: 'a.png', length: 4)],
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(container.read(attachmentStagingProvider('c1')).isEmpty, isTrue);
    expect(container.read(shareHandoffProvider), isNull);
    expect(find.text(shareRefusedNotice), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester);
  });
}
