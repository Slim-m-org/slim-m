// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The profile picture is the control: tapping it opens the photo menu, and
/// the standalone "Remove photo" link is gone.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/attachment_picker.dart';
import 'package:slimm_app/src/widgets/avatar_photo_menu.dart';
import 'package:slimm_app/src/widgets/avatar_settings_section.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);
const _avatarLabel = 'Change profile picture';
const _json = {'content-type': 'application/json'};

class _Rig {
  _Rig({required bool hasPhoto, required bool camera, bool cameraFails = false})
    : requests = [],
      pickedSources = [],
      captures = [] {
    container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
        attachmentPickerProvider.overrideWith(
          (ref, source) => () async {
            pickedSources.add(source);
            return null;
          },
        ),
        avatarCameraCaptureProvider.overrideWithValue(
          camera
              ? () async {
                  captures.add('capture');
                  if (cameraFails) throw StateError('camera_access_denied');
                  return null;
                }
              : null,
        ),
        apiProvider.overrideWith((ref) {
          final api = SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((request) async {
              requests.add('${request.method} ${request.url.path}');
              if (request.url.path == '/me' && request.method == 'GET') {
                return http.Response(
                  jsonEncode({
                    'id': 'self',
                    'username': 'self',
                    'display_name': 'Self',
                    'created_at': 0,
                    'permissions': 0,
                    if (hasPhoto) 'avatar_updated_at': 5,
                  }),
                  200,
                  headers: _json,
                );
              }
              return http.Response('', 204);
            }),
          );
          ref.onDispose(api.close);
          return api;
        }),
      ],
    );
  }

  late final ProviderContainer container;
  final List<String> requests;
  final List<AttachmentSource> pickedSources;
  final List<String> captures;

  Widget get app => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: const Scaffold(body: AvatarSettingsSection()),
    ),
  );
}

Future<_Rig> _pump(
  WidgetTester tester, {
  required double width,
  bool hasPhoto = true,
  bool camera = false,
  bool cameraFails = false,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final rig = _Rig(
    hasPhoto: hasPhoto,
    camera: camera,
    cameraFails: cameraFails,
  );
  addTearDown(rig.container.dispose);
  await tester.pumpWidget(rig.app);
  await tester.pumpAndSettle();
  return rig;
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.bySemanticsLabel(_avatarLabel));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('no standalone Remove photo link sits on the card', (t) async {
    await _pump(t, width: 390);
    expect(find.text('Remove photo'), findsNothing);
  });

  testWidgets('the card is compact and the avatar target clears 44', (t) async {
    await _pump(t, width: 390);
    final card = t.getSize(find.byType(AppCard));
    expect(card.height, lessThan(90));
    final target = t.getSize(find.bySemanticsLabel(_avatarLabel));
    expect(target.shortestSide, greaterThanOrEqualTo(44));
  });

  testWidgets('phone menu: a sheet, Remove only with a photo', (t) async {
    await _pump(t, width: 390);
    await _openMenu(t);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('Take photo'), findsNothing);
    expect(find.text('Choose photo'), findsOneWidget);
    expect(find.text('Browse files'), findsOneWidget);
    expect(find.text('Remove photo'), findsOneWidget);
    final row = t.getSize(find.widgetWithText(AppMenuItem, 'Choose photo'));
    expect(row.height, greaterThanOrEqualTo(44));
  });

  testWidgets('no photo means no Remove row', (t) async {
    await _pump(t, width: 390, hasPhoto: false);
    await _openMenu(t);
    expect(find.text('Choose photo'), findsOneWidget);
    expect(find.text('Remove photo'), findsNothing);
  });

  testWidgets('Take photo appears only when a camera is injected', (t) async {
    final rig = await _pump(t, width: 390, camera: true);
    await _openMenu(t);
    expect(find.text('Take photo'), findsOneWidget);
    await t.tap(find.text('Take photo'));
    await t.pumpAndSettle();
    expect(rig.captures, ['capture']);
    expect(rig.requests, isNot(contains('POST /me/avatar')));
  });

  testWidgets('a denied camera shows the persistent error, no snackbar', (
    t,
  ) async {
    await _pump(t, width: 390, camera: true, cameraFails: true);
    await _openMenu(t);
    await t.tap(find.text('Take photo'));
    await t.pumpAndSettle();
    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.text('Could not open the camera.'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  test('the default capture exists on phones and not on desktop', () {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    for (final (platform, reachable) in [
      (TargetPlatform.android, true),
      (TargetPlatform.iOS, true),
      (TargetPlatform.linux, false),
      (TargetPlatform.windows, false),
      (TargetPlatform.macOS, false),
    ]) {
      debugDefaultTargetPlatformOverride = platform;
      final container = ProviderContainer();
      expect(
        container.read(avatarCameraCaptureProvider) != null,
        reachable,
        reason: '$platform',
      );
      container.dispose();
    }
  });

  testWidgets('Choose and Browse run their own picker source', (t) async {
    final rig = await _pump(t, width: 390);
    await _openMenu(t);
    await t.tap(find.text('Choose photo'));
    await t.pumpAndSettle();
    await _openMenu(t);
    await t.tap(find.text('Browse files'));
    await t.pumpAndSettle();
    expect(rig.pickedSources, [
      AttachmentSource.photoLibrary,
      AttachmentSource.fileBrowser,
    ]);
  });

  testWidgets('Remove photo sends the delete request', (t) async {
    final rig = await _pump(t, width: 390);
    await _openMenu(t);
    await t.tap(find.text('Remove photo'));
    await t.pumpAndSettle();
    expect(rig.requests, contains('DELETE /me/avatar'));
  });

  testWidgets('desktop width shows the floating menu, not a sheet', (t) async {
    await _pump(t, width: 1280);
    await _openMenu(t);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(AppMenu), findsOneWidget);
    expect(find.text('Remove photo'), findsOneWidget);
  });
}
