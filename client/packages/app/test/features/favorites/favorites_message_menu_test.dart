// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Add to favorites on an image or video in a message: it appears only on a
/// sent message, stores a reference, and reports a refusal in place.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/favorites/providers/favorites_controller.dart';
import 'package:slimm_app/src/features/messages/providers/attachment_bytes.dart';
import 'package:slimm_app/src/features/messages/providers/attachment_preview_bytes.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_video_player.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_video_source.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_view.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAT0lEQVR42u3PQQkA'
  'AAgEsAtmMCMaywi+hcEKLNP1WgQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE'
  'BAQEBAQEBAQEBAQEBAQEBAQELguFPsFaQDQP9QAAAABJRU5ErkJggg==',
);

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _image = api.Attachment(
  id: 'a1',
  filename: 'holiday.png',
  contentType: 'image/png',
  size: 2048,
);

const _video = api.Attachment(
  id: 'v1',
  filename: 'clip.mp4',
  contentType: 'video/mp4',
  size: 4096,
);

/// Never finishes opening, so the player stays out of the platform video code.
class _HangingSource implements AttachmentVideoSource {
  @override
  Future<Media> open({
    required api.SlimmApi apiClient,
    required api.Attachment attachment,
    required void Function(double? progress) onProgress,
  }) => Completer<Media>().future;

  @override
  bool isStale(api.SlimmApi apiClient) => false;

  @override
  void dispose() {}
}

class _Server {
  _Server({this.refuse = false});

  final bool refuse;
  final posts = <Map<String, Object?>>[];

  Future<http.Response> handle(http.Request request) async {
    if (request.method == 'POST' && request.url.path == '/favorites') {
      final body = jsonDecode(request.body) as Map<String, Object?>;
      posts.add(body);
      if (refuse) {
        return http.Response(
          jsonEncode({'error': 'no such message'}),
          404,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode({
          'id': body['id'],
          'kind': 'attachment',
          'title': 'x',
          'width': 0,
          'height': 0,
          'available': true,
          'created_at': 1,
        }),
        201,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.Response('unexpected ${request.url.path}', 500);
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Server server,
  api.Attachment attachment, {
  String? messageId = 'm1',
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      mockApiOverride(server.handle),
      attachmentVideoSourceProvider.overrideWithValue(_HangingSource.new),
      attachmentBytesProvider.overrideWith((ref, id) async => _png),
      attachmentPreviewBytesProvider.overrideWith((ref, key) async => _png),
    ],
  );
  addTearDown(container.dispose);
  await tester.runAsync(() async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 400,
                height: 300,
                child: AttachmentView(
                  attachment: attachment,
                  messageId: messageId,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await tester.pump(const Duration(milliseconds: 100));
  return container;
}

Future<void> _openMenu(WidgetTester tester, Finder target) async {
  await tester.tap(target, buttons: kSecondaryButton);
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _pickAddItem(WidgetTester tester) async {
  await tester.tap(find.text('Add to favorites'));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  setUpAll(MediaKit.ensureInitialized);

  testWidgets('an image on a sent message can be favorited by reference', (
    tester,
  ) async {
    final server = _Server();
    final container = await _pump(tester, server, _image);

    await _openMenu(tester, find.byKey(const ValueKey('attachment-menu-a1')));
    await _pickAddItem(tester);
    await tester.pump(const Duration(seconds: 5));

    expect(server.posts, hasLength(1));
    expect(server.posts.single['kind'], 'attachment');
    expect(server.posts.single['message_id'], 'm1');
    expect(server.posts.single['attachment_id'], 'a1');
    expect(container.read(favoritesProvider).requireValue, hasLength(1));
  });

  testWidgets('a refusal shows in place instead of failing silently', (
    tester,
  ) async {
    final server = _Server(refuse: true);
    await _pump(tester, server, _image);

    await _openMenu(tester, find.byKey(const ValueKey('attachment-menu-a1')));
    await _pickAddItem(tester);

    expect(find.textContaining('favorite holiday.png'), findsOneWidget);
  });

  testWidgets('an image with no message behind it offers no favorite', (
    tester,
  ) async {
    await _pump(tester, _Server(), _image, messageId: null);

    await _openMenu(tester, find.byKey(const ValueKey('attachment-menu-a1')));

    expect(find.text('Copy image'), findsOneWidget);
    expect(find.text('Add to favorites'), findsNothing);
  });

  testWidgets('a video offers Add to favorites in its own menu', (
    tester,
  ) async {
    final server = _Server();
    await _pump(tester, server, _video);

    await _openMenu(tester, find.byKey(const ValueKey('attachment-menu-v1')));
    await _pickAddItem(tester);
    await tester.pump(const Duration(seconds: 5));

    expect(server.posts.single['attachment_id'], 'v1');
  });
}
