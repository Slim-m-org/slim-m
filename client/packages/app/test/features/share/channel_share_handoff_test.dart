// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A share given to a conversation is staged by that conversation's real
/// composer once it mounts: the files appear as attachments, the server's size
/// limit is explained inline, and nothing is sent.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_attachments.dart';
import 'package:slimm_app/src/features/share/providers/incoming_share.dart';
import 'package:slimm_app/src/features/share/widgets/channel_share_handoff.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_test_support/slimm_test_support.dart';

import '../composer/composer_harness.dart';

api.SlimmApi Function(Ref) _server({int? maxBytes, List<String>? uploads}) =>
    (ref) => testApi((request) async {
      if (request.url.path == '/version') {
        return http.Response(
          jsonEncode({
            'name': 'slim-m',
            'version': '1.0.0',
            'protocol': 1,
            'max_attachment_bytes': ?maxBytes,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.method == 'POST' && request.url.path == '/attachments') {
        final name = request.url.queryParameters['filename'] ?? '';
        uploads?.add(name);
        return http.Response(
          jsonEncode({
            'id': 'id-$name',
            'filename': name,
            'content_type': 'application/octet-stream',
            'size': 4,
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    }, session: ref.watch(sessionProvider));

void main() {
  late Directory dir;
  late TextEditingController controller;
  late Sends sends;
  late AttachmentStagingController Function() staging;
  late ProviderContainer Function() containerOf;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controller = TextEditingController();
    sends = Sends();
    dir = Directory.systemTemp.createTempSync('share-handoff-test');
  });

  tearDown(() {
    controller.dispose();
    dir.deleteSync(recursive: true);
  });

  SharedFile file(String name, int length) {
    final path = '${dir.path}/$name';
    File(path).writeAsBytesSync(Uint8List(length));
    return SharedFile(path: path, name: name, length: length);
  }

  Future<void> pumpComposer(
    WidgetTester tester, {
    int? maxBytes,
    List<String>? uploads,
    String listenOn = 'c1',
    Size size = const Size(390, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.android,
        apiBuilder: _server(maxBytes: maxBytes, uploads: uploads),
        extra: Consumer(
          builder: (context, ref, _) {
            staging = () => ref.read(attachmentStagingProvider('c1'));
            containerOf = () => ProviderScope.containerOf(context);
            return ChannelShareHandoff(
              channelId: listenOn,
              child: const SizedBox.shrink(),
            );
          },
        ),
      ),
    );
    await tester.pump();
  }

  void hand(String channelId, IncomingShare share) =>
      containerOf().read(shareHandoffProvider.notifier).state = (
        channelId: channelId,
        share: share,
      );

  /// Real file reads complete outside the fake clock, so alternate the two.
  Future<void> untilStaged(WidgetTester tester, int count) async {
    for (var i = 0; i < 400 && staging().items.length < count; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('files land staged and uploading, and nothing is sent', (
    tester,
  ) async {
    final uploads = <String>[];
    await pumpComposer(tester, uploads: uploads);

    hand('c1', IncomingShare(files: [file('a.jpg', 4), file('b.pdf', 4)]));
    await tester.pump();
    await untilStaged(tester, 2);

    expect(staging().items.map((a) => a.filename), ['a.jpg', 'b.pdf']);
    expect(find.text('a.jpg'), findsOneWidget);
    expect(find.text('b.pdf'), findsOneWidget);
    expect(containerOf().read(shareHandoffProvider), isNull);
    expect(sends.count, 0);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    expect(uploads, containsAll(['a.jpg', 'b.pdf']));
  });

  testWidgets('a file over the server limit is refused inline, not staged', (
    tester,
  ) async {
    final uploads = <String>[];
    await pumpComposer(tester, maxBytes: 1024, uploads: uploads);

    hand('c1', IncomingShare(files: [file('big.mov', 4000)]));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.textContaining("big.mov is 3.9 KB, over this server's limit"),
      findsOneWidget,
    );
    expect(staging().items, isEmpty);
    expect(uploads, isEmpty);
  });

  testWidgets('only what fits in one message is staged, and it says so', (
    tester,
  ) async {
    // Ten staged tiles are taller than a phone.
    await pumpComposer(tester, size: const Size(390, 2400));

    hand(
      'c1',
      IncomingShare(
        files: [
          for (var i = 0; i < kMaxSharedFiles + 2; i++) file('f$i.bin', 4),
        ],
      ),
    );
    await tester.pump();
    await untilStaged(tester, kMaxSharedFiles);

    expect(staging().items, hasLength(kMaxSharedFiles));
    expect(
      find.text('Only the first $kMaxSharedFiles files fit in one message.'),
      findsOneWidget,
    );
  });

  testWidgets('items the platform would not let slim-m read are reported', (
    tester,
  ) async {
    await pumpComposer(tester);

    hand('c1', IncomingShare(files: [file('a.jpg', 4)], unreadable: 1));
    await tester.pump();
    await untilStaged(tester, 1);

    expect(
      find.text('One shared item could not be read, so it is left out.'),
      findsOneWidget,
    );
  });

  testWidgets('a share for another conversation is left waiting', (
    tester,
  ) async {
    await pumpComposer(tester, listenOn: 'c2');

    hand('c1', IncomingShare(files: [file('a.jpg', 4)]));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(staging().items, isEmpty);
    expect(containerOf().read(shareHandoffProvider)?.channelId, 'c1');
  });
}
