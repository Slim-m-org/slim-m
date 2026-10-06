// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A paste or an error report that outlives its pane must leave the disposed
/// document and engine alone.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/screens/canvas/canvas_image_paste.dart';
import 'package:slimm_app/src/screens/canvas/canvas_engine.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_pane_harness.dart';

const _channel = MethodChannel('top.npcserver.slimm/clipboard_image');

void _mockClipboard() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
        switch (call.method) {
          case 'hasImage':
            return true;
          case 'readImage':
            return canvasPngFixture;
          default:
            return null;
        }
      });
}

api.SlimmApi _client(Completer<http.Response> place) => api.SlimmApi(
  baseUrl: Uri.parse('http://localhost:8080'),
  session: api.SessionStore(tokens: testTokens),
  httpClient: MockClient((request) async {
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
      return place.future;
    }
    return jsonResponse(<Object>[]);
  }),
);

void main() {
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  testWidgets(
    'a paste that finishes after the pane stopped must not touch the document',
    (tester) async {
      _mockClipboard();
      final document = CanvasDocument()..setViewport(const Size(400, 300));
      final log = <String>[];
      late Completer<http.Response> place;
      late CanvasImagePaste paste;
      void build() {
        place = Completer<http.Response>();
        paste = CanvasImagePaste(
          client: _client(place),
          channelId: 'c1',
          document: document,
          onPlaced: (id) => log.add('placed $id'),
          onError: (m) => log.add('error $m'),
          timedOutUntil: () => null,
        );
      }

      await tester.runAsync(() async {
        build();
        final done = paste.pasteAt(const Offset(10, 10)).catchError((Object e) {
          log.add('threw ${e.runtimeType}: $e'.split('\n').first);
        });
        await Future<void>.delayed(const Duration(milliseconds: 200));
        paste.stop();
        document.dispose();
        place.complete(
          http.Response(
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
          ),
        );
        await done;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      expect(log.where((l) => l != 'error null'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  test('reportError after the engine is disposed is a no-op', () async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    final sub = container.listen(canvasEngineProvider('c1'), (_, _) {});
    final engine = container.read(canvasEngineProvider('c1').notifier);
    await container.pump();
    sub.close();
    await container.pump();
    expect(engine.mounted, isFalse);

    expect(
      () => engine.reportError('That image could not be pasted.'),
      returnsNormally,
    );
  });
}
