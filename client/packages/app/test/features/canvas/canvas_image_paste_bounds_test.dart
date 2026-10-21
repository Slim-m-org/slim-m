// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A pasted image is decoded no larger than it is drawn, refused past a pixel
/// ceiling before any pixel is allocated, and counted in the image budget.
library;

import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_image_paste.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/pixel_bomb_png.dart';
import 'canvas_pane_harness.dart';

const _channel = MethodChannel('top.npcserver.slimm/clipboard_image');

void _mockClipboard(Uint8List png) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
        switch (call.method) {
          case 'hasImage':
            return true;
          case 'readImage':
            return png;
          default:
            return null;
        }
      });
}

void main() {
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  testWidgets('a pixel-bomb paste is refused and never uploaded', (
    tester,
  ) async {
    _mockClipboard(pixelBombPng(8000));
    final document = CanvasDocument()..setViewport(const Size(400, 300));
    final requests = <String>[];
    final errors = <String?>[];
    final paste = CanvasImagePaste(
      client: testApi((request) async {
        requests.add('${request.method} ${request.url.path}');
        return jsonResponse(<Object>[]);
      }, session: api.SessionStore(tokens: testTokens)),
      channelId: 'c1',
      document: document,
      onPlaced: (_) {},
      onError: errors.add,
      timedOutUntil: () => null,
    );
    addTearDown(document.dispose);
    addTearDown(paste.stop);

    await tester.runAsync(() async {
      await paste.pasteAt(const Offset(10, 10));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });

    expect(errors, contains('That image is too large.'));
    expect(requests, isEmpty);
  });

  testWidgets('a placed paste reports its bitmap to the image budget', (
    tester,
  ) async {
    _mockClipboard(canvasPngFixture);
    final document = CanvasDocument()..setViewport(const Size(400, 300));
    final attached = <(String, ui.Image)>[];
    final paste = CanvasImagePaste(
      client: testApi((request) async {
        if (request.url.path == '/attachments' && request.method == 'POST') {
          return jsonResponse({
            'id': 'sha-pasted',
            'filename': 'pasted-image.png',
            'content_type': 'image/png',
            'size': canvasPngFixture.length,
          });
        }
        if (request.url.path.endsWith('/canvas/objects') &&
            request.method == 'POST') {
          return http.Response(
            jsonEncode({
              ...canvasObjectJson('p1'),
              'kind': 'image',
              'props': {
                'attachment': 'sha-pasted',
                'content_type': 'image/png',
                'width': 1,
                'height': 1,
              },
            }),
            201,
            headers: {'content-type': 'application/json'},
          );
        }
        return jsonResponse(<Object>[]);
      }, session: api.SessionStore(tokens: testTokens)),
      channelId: 'c1',
      document: document,
      onPlaced: (_) {},
      onError: (_) {},
      timedOutUntil: () => null,
      onBitmapAttached: (id, image) => attached.add((id, image)),
    );
    addTearDown(document.dispose);
    addTearDown(paste.stop);

    await tester.runAsync(() async {
      await paste.pasteAt(const Offset(10, 10));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });

    expect(attached.map((a) => a.$1), ['p1']);
    expect(document.hasImageBitmap('p1'), isTrue);
  });
}
