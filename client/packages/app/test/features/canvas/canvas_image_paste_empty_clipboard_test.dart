// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// C-022: "Paste image" on a clipboard holding no image (or on a platform
/// with no clipboard image channel at all) must say so, not do nothing.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_image_paste.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_pane_harness.dart';

const _channel = MethodChannel('top.npcserver.slimm/clipboard_image');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  for (final handled in [true, false]) {
    test(
      'the Paste image button reports no image when the clipboard has none '
      '(${handled ? "channel answers empty" : "no channel handler"})',
      () async {
        if (handled) {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(_channel, (call) async {
                return call.method == 'hasImage' ? false : null;
              });
        }
        final errors = <String?>[];
        final paste = CanvasImagePaste(
          client: testApi(
            (request) async => jsonResponse(<Object>[]),
            session: api.SessionStore(tokens: testTokens),
          ),
          channelId: 'c1',
          document: CanvasDocument()..setViewport(const Size(400, 300)),
          onPlaced: (_) {},
          onError: errors.add,
          timedOutUntil: () => null,
        );

        await paste.pasteFromButton();

        expect(
          errors.whereType<String>(),
          isNotEmpty,
          reason: 'the button gave no feedback; got $errors',
        );
      },
    );
  }
}
