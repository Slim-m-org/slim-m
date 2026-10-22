// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The channel rail with a DM peer and voice occupants who have pictures:
/// the DM row and the occupant strip must draw them, and a person with no
/// picture keeps initials. Desktop and phone, both themes.
library;

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart'
    show apiProvider, sessionProvider;
import 'package:slimm_app/src/features/channels/widgets/dm_row.dart';
import 'package:slimm_design_system/design_system.dart';

import 'ui_snapshot_support.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

/// A high-contrast pattern, so a blurry or mis-scaled decode shows in the PNG.
Future<Uint8List> _patternPng() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 512, 512),
    Paint()..color = const Color(0xFF1F6FEB),
  );
  final ring = Paint()
    ..color = const Color(0xFFFFD33D)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 40;
  canvas.drawCircle(const Offset(256, 256), 150, ring);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 256, 256),
    Paint()..color = const Color(0xFFDA3633),
  );
  final image = await recorder.endRecording().toImage(512, 512);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

api.SlimmApi Function(Ref) _client(Uint8List png) =>
    (ref) => testApi((request) async {
      final path = request.url.path;
      if (path.endsWith('/users/user-ada/avatar')) {
        return http.Response.bytes(
          png,
          200,
          headers: {'content-type': 'image/png'},
        );
      }
      if (path == '/users') {
        return http.Response(
          jsonEncode([
            {
              'id': 'user-ada',
              'username': 'ada',
              'display_name': 'Ada Lovelace',
              'created_at': 0,
              'avatar_updated_at': 1,
              'roles': <String>[],
            },
          ]),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path.endsWith('/c-main/voice/roster')) {
        return http.Response(
          jsonEncode({
            'participants': [
              {'user_id': 'user-ada', 'display_name': 'Ada Lovelace'},
              {'user_id': 'user-nick', 'display_name': 'Nick'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return fixtureResponse(request);
    }, session: ref.watch(sessionProvider));

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in const ['desktop', 'phone-portrait']) {
    for (final theme in const [darkAndLight]) {
      testWidgets('rail avatars at $viewport ($theme)', (tester) async {
        final png = (await tester.runAsync(_patternPng))!;
        final route = viewport == 'desktop'
            ? '/channels/c-general'
            : '/channels';
        await renderSurface(
          tester,
          route,
          viewport,
          theme,
          'rail-avatars-$viewport-$theme',
          overrides: [apiProvider.overrideWith(_client(png))],
          afterSettle: (tester) async {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 100)),
            );
            await tester.pump(const Duration(milliseconds: 350));
            final dm = find.byType(DmRow);
            if (dm.evaluate().isNotEmpty) {
              final avatar = tester.widget<AppAvatar>(
                find.descendant(of: dm, matching: find.byType(AppAvatar)),
              );
              expect(avatar.image, isNotNull);
            }
          },
        );
      });
    }
  }
}
