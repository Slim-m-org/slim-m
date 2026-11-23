// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sequence an owner sees: a freshly received gallery on a cold start, a tile
/// opened in the viewer and closed again. The tile is sharp from the first
/// frame, and opening the viewer fetches the original without touching it.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/attachment_preview_quality.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_gallery.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_view.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_design_system/design_system.dart';
import '../../support/fake_sync.dart';
import '../../support/fake_api.dart';

Future<Uint8List> _photo(int longest, double ratio) async {
  final w = longest, h = (longest / ratio).round();
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = Colors.teal,
  );
  final img = await rec.endRecording().toImage(w, h);
  final d = await img.toByteData(format: ui.ImageByteFormat.png);
  return d!.buffer.asUint8List();
}

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 0,
);

void main() {
  testWidgets(
    'a cold-start gallery is sharp at once and the viewer changes nothing',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        attachmentPreviewQualityKey: 'sharp',
      });
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final byW = <String, Uint8List>{};
      await tester.runAsync(() async {
        for (final b in [320, 640, 1280, 4000]) {
          byW['$b'] = await _photo(b, 4 / 3);
        }
      });
      final requests = <String>[];
      final attachments = [
        for (var i = 0; i < 4; i++)
          api.Attachment(
            id: 'img-$i',
            filename: 'p$i.jpg',
            contentType: 'image/jpeg',
            size: 4000000,
          ),
      ];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sessionProvider.overrideWithValue(
              api.SessionStore(tokens: _tokens),
            ),
            syncControllerProvider.overrideWith(NoopSyncController.new),
            mockApiOverride((r) async {
              requests.add('${r.url.path}?${r.url.query}');
              final bytes = byW[r.url.queryParameters['w'] ?? '4000']!;
              return http.Response.bytes(
                bytes,
                200,
                headers: {'content-type': 'image/png'},
              );
            }),
          ],
          child: MaterialApp(
            theme: buildTheme(Brightness.dark, AppTokens.dark),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 500,
                  child: MessageAttachments(attachments: attachments),
                ),
              ),
            ),
          ),
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byWidgetPredicate((w) => w is Scaffold)),
      );
      // Preferences arrive after the first frame, as on a cold start.
      await tester.runAsync(
        () => container
            .read(attachmentPreviewQualityControllerProvider.notifier)
            .restore(),
      );

      Future<void> settle() async {
        for (var i = 0; i < 6; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      Future<List<({double edge, int shorter})>> tiles() async {
        final out = <({double edge, int shorter})>[];
        final views = tester.widgetList<AttachmentView>(
          find.byWidgetPredicate((w) => w is AttachmentView),
        );
        for (final view in views) {
          final image = tester.widget<Image>(
            find.descendant(
              of: find.byWidget(view),
              matching: find.byWidgetPredicate((w) => w is Image),
            ),
          );
          final done = Completer<ui.Image>();
          final stream = image.image.resolve(ImageConfiguration.empty);
          late ImageStreamListener listener;
          listener = ImageStreamListener((info, _) {
            done.complete(info.image);
            stream.removeListener(listener);
          });
          stream.addListener(listener);
          final decoded = await tester.runAsync(() => done.future);
          out.add((
            edge: tester.getSize(find.byWidget(view)).width,
            shorter: math.min(decoded!.width, decoded.height),
          ));
        }
        return out;
      }

      await settle();
      final first = await tiles();
      expect(first, hasLength(4));
      for (final t in first) {
        expect(t.shorter, greaterThanOrEqualTo(t.edge.floor()));
      }
      expect(requests.where((r) => r.contains('w=')), hasLength(4));

      await tester.tap(find.byWidgetPredicate((w) => w is Image).first);
      await settle();
      expect(requests.where((r) => !r.contains('w=')), ['/attachments/img-0?']);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle();

      expect(await tiles(), first);
      expect(requests.where((r) => r.contains('w=')), hasLength(4));
    },
  );
}
