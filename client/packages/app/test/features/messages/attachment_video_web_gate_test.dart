// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A browser buffers a whole video before playing it, so a big one waits for a
/// tap and an unfinished fetch is dropped when its row scrolls away.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/widgets/attachment_video_player.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_video_source.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

import 'attachment_video_fakes.dart';

class _PendingSource extends ScriptedSource {
  _PendingSource() : super(const []);

  final fetch = Completer<Media>();

  @override
  Future<Media> open({
    required api.SlimmApi apiClient,
    required api.Attachment attachment,
    required void Function(double? progress) onProgress,
  }) {
    opens += 1;
    return fetch.future;
  }

  @override
  void cancel() {
    super.cancel();
    if (!fetch.isCompleted) fetch.completeError(Exception('aborted'));
  }
}

const _big = api.Attachment(
  id: 'big',
  filename: 'film.mp4',
  contentType: 'video/mp4',
  size: kWebVideoAutoloadMax + 1,
);

Future<void> _pump(
  WidgetTester tester,
  AttachmentVideoSource source,
  api.Attachment attachment,
  ScrollController controller, {
  bool buffers = true,
}) => tester.pumpWidget(
  ProviderScope(
    overrides: [
      apiProvider.overrideWithValue(
        api.SlimmApi(baseUrl: Uri.parse('http://localhost:1')),
      ),
      attachmentVideoSourceProvider.overrideWithValue(() => source),
      attachmentPlayerProvider.overrideWithValue(FakePlayer.new),
      attachmentVideoControllerProvider.overrideWithValue(
        (_) => FakeVideoController(),
      ),
      attachmentVideoBuffersWholeFileProvider.overrideWithValue(buffers),
    ],
    child: MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(
        body: ListView(
          controller: controller,
          scrollCacheExtent: const ScrollCacheExtent.pixels(6000),
          children: [
            AttachmentVideoPlayer(attachment: attachment),
            const SizedBox(height: 3000),
          ],
        ),
      ),
    ),
  ),
);

void main() {
  setUpAll(MediaKit.ensureInitialized);

  late ScrollController controller;
  setUp(() => controller = ScrollController());
  tearDown(() => controller.dispose());

  testWidgets('a large video is not fetched until it is tapped', (
    tester,
  ) async {
    final source = _PendingSource();
    await _pump(tester, source, _big, controller);
    await tester.pump();
    await tester.pump();

    expect(source.opens, 0);
    expect(find.textContaining('Tap to load'), findsOneWidget);

    await tester.tap(find.textContaining('Tap to load'));
    await tester.pump();
    await tester.pump();

    expect(source.opens, 1);
  });

  testWidgets('a small video still loads on its own', (tester) async {
    final source = _PendingSource();
    await _pump(tester, source, videoAttachment, controller);
    await tester.pump();
    await tester.pump();

    expect(source.opens, 1);
    expect(find.textContaining('Tap to load'), findsNothing);
  });

  testWidgets('a native client never holds a large video behind a tap', (
    tester,
  ) async {
    final source = _PendingSource();
    await _pump(tester, source, _big, controller, buffers: false);
    await tester.pump();
    await tester.pump();

    expect(source.opens, 1);
  });

  testWidgets('scrolling away aborts the fetch and asks for a tap again', (
    tester,
  ) async {
    final source = _PendingSource();
    await _pump(tester, source, _big, controller);
    await tester.pump();
    await tester.tap(find.textContaining('Tap to load'));
    await tester.pump();
    await tester.pump();
    expect(source.opens, 1);
    expect(source.cancels, 0);

    controller.jumpTo(2500);
    await tester.pump();
    await tester.pump();

    expect(source.cancels, 1);
    expect(find.textContaining('Could not load'), findsNothing);

    controller.jumpTo(0);
    await tester.pump();
    await tester.pump();

    expect(source.opens, 1, reason: 'not refetched without a new tap');
    expect(find.textContaining('Tap to load'), findsOneWidget);
  });
}
