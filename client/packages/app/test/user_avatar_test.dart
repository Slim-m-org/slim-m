// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for [UserAvatar]: the real picture is wired in
/// once its bytes resolve, and a user with none (or with an id not yet
/// resolved) still falls back to the same initials [AppAvatar] always draws.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/ui_scale_frame.dart';
import 'package:slimm_app/src/widgets/user_avatar.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _harness(Widget child, {required List<Override> overrides}) =>
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: child),
      ),
    );

List<Override> _apiOverrides(
  Future<http.Response> Function(http.Request request) handler,
) => [
  apiProvider.overrideWith((ref) {
    final api = SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: SessionStore(
        tokens: const TokenPair(
          userId: 'self',
          accessToken: 'access',
          refreshToken: 'refresh',
          accessExpiresAt: 0,
        ),
      ),
      httpClient: MockClient(handler),
    );
    ref.onDispose(api.close);
    return api;
  }),
];

void main() {
  testWidgets('no userId renders initials and makes no fetch', (tester) async {
    var requested = false;
    await tester.pumpWidget(
      _harness(
        const UserAvatar(name: 'Priya Shah', userId: null, size: 40),
        overrides: _apiOverrides((request) async {
          requested = true;
          return http.Response('', 404);
        }),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('PR'), findsOneWidget);
    expect(find.byType(AppShapedImage), findsNothing);
    expect(requested, isFalse);
  });

  testWidgets('a known userId with resolved bytes renders through AppShapedImage', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final bytes = Uint8List.fromList(const [1, 2, 3, 4]);
    await tester.pumpWidget(
      _harness(
        const UserAvatar.known(
          name: 'Priya Shah',
          userId: 'u1',
          avatarUpdatedAt: 42,
          size: 40,
        ),
        overrides: _apiOverrides((request) async {
          expect(request.url.path, '/users/u1/avatar');
          return http.Response.bytes(
            bytes,
            200,
            headers: {'content-type': 'image/png'},
          );
        }),
      ),
    );
    await tester.pumpAndSettle();

    /// Not asserting the initials are gone: the bytes above are not valid
    /// image data, so [AppShapedImage.errorBuilder] fires and repaints them right back
    /// in. What matters here is that the right bytes actually reached the
    /// widget, which the assertion above already establishes.
    final image = tester.widget<AppShapedImage>(find.byType(AppShapedImage));
    final resized = image.image as ResizeImage;
    expect((resized.imageProvider as MemoryImage).bytes, bytes);
    // 1x display: floored at a 2x ratio for a window-scaled desktop that under-reports it, then 3x headroom for the GPU to minify from.
    expect(resized.width, 240);
    expect(resized.height, 240);
    // medium, not high: measured on Skia, high aliased the minified photo worse, and Impeller GLES draws both the same.
    expect(image.filterQuality, FilterQuality.medium);
  });

  testWidgets('the decode cap scales with the device pixel ratio', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final bytes = Uint8List.fromList(const [1, 2, 3, 4]);
    await tester.pumpWidget(
      _harness(
        const UserAvatar.known(
          name: 'Priya Shah',
          userId: 'u1',
          avatarUpdatedAt: 42,
          size: 40,
        ),
        overrides: _apiOverrides(
          (request) async => http.Response.bytes(
            bytes,
            200,
            headers: {'content-type': 'image/png'},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final resized =
        tester.widget<AppShapedImage>(find.byType(AppShapedImage)).image
            as ResizeImage;
    // A 3x screen decodes at 3x the painted pixels, because the engine's own downscale aliases when it lands on the painted size.
    expect(resized.width, 360);
    expect(resized.height, 360);
  });

  testWidgets('a scaled UI decodes past the pixels it paints', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final bytes = Uint8List.fromList(const [1, 2, 3, 4]);
    await tester.pumpWidget(
      _harness(
        Builder(
          builder: (context) => MediaQuery(
            data: scaleMediaQuery(MediaQueryData.fromView(tester.view), 2.5),
            child: const UserAvatar.known(
              name: 'Priya Shah',
              userId: 'u1',
              avatarUpdatedAt: 42,
              size: 40,
            ),
          ),
        ),
        overrides: _apiOverrides(
          (request) async => http.Response.bytes(
            bytes,
            200,
            headers: {'content-type': 'image/png'},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final resized =
        tester.widget<AppShapedImage>(find.byType(AppShapedImage)).image
            as ResizeImage;
    // 40 logical at 2.5x paints 100px; 3x of that, past the 2x floor.
    expect(resized.width, 300);
  });

  testWidgets('a 404 (no avatar on the server) still falls back to initials', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        const UserAvatar.known(
          name: 'Priya Shah',
          userId: 'u1',
          avatarUpdatedAt: 42,
          size: 40,
        ),
        overrides: _apiOverrides((request) async => http.Response('', 404)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('PR'), findsOneWidget);
    expect(find.byType(AppShapedImage), findsNothing);
  });

  testWidgets('UserAvatar resolves the profile before fetching the picture', (
    tester,
  ) async {
    final bytes = Uint8List.fromList(const [9, 9, 9]);
    await tester.pumpWidget(
      _harness(
        const UserAvatar(name: 'Kess', userId: 'u2', size: 36),
        overrides: _apiOverrides((request) async {
          if (request.url.path == '/users') {
            return http.Response(
              jsonEncode([
                {
                  'id': 'u2',
                  'username': 'kess',
                  'display_name': 'Kess',
                  'created_at': 0,
                  'avatar_updated_at': 7,
                },
              ]),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          expect(request.url.path, '/users/u2/avatar');
          return http.Response.bytes(
            bytes,
            200,
            headers: {'content-type': 'image/png'},
          );
        }),
      ),
    );
    await tester.pumpAndSettle();

    final image = tester.widget<AppShapedImage>(find.byType(AppShapedImage));
    final resized = image.image as ResizeImage;
    expect((resized.imageProvider as MemoryImage).bytes, bytes);
  });

  testWidgets('a null author id (a deleted account) never triggers a lookup', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        const UserAvatar(name: 'Deleted user', userId: null, size: 36),
        overrides: _apiOverrides(
          (request) async =>
              throw StateError('unexpected request: ${request.url}'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('DE'), findsOneWidget);
  });
}
