// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The admin controls for the invite landing card: saving the description,
/// uploading and removing the banner, and the failure shape.
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
import 'package:slimm_app/src/widgets/attachment_picker.dart';
import 'package:slimm_app/src/widgets/image_drop_zone.dart';
import 'package:slimm_app/src/widgets/invite_landing_card.dart';
import 'package:slimm_app/src/widgets/invite_landing_section.dart';
import 'package:slimm_app/src/widgets/invite_landing_view.dart';
import 'package:slimm_app/src/widgets/space_icon.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'composer_harness.dart' show FakePlatformFile;

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

// A 1x1 PNG: real enough for the crop sheet to lay itself out.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

const _json = {'content-type': 'application/json'};

class _Server {
  String description = '';
  int? banner;
  int? icon;
  final calls = <String>[];
  Object? lastPatch;
  int uploadStatus = 200;

  http.Response handle(http.Request r) {
    calls.add('${r.method} ${r.url.path}');
    switch ((r.method, r.url.path)) {
      case ('GET', '/space/settings'):
        return http.Response(_settings(), 200, headers: _json);
      case ('PATCH', '/space/settings'):
        lastPatch = jsonDecode(r.body);
        description = (lastPatch as Map)['description'] as String;
        return http.Response(_settings(), 200, headers: _json);
      case ('POST', '/space/banner'):
        if (uploadStatus != 200) {
          return http.Response(
            jsonEncode({'error': 'unsupported banner type'}),
            uploadStatus,
            headers: _json,
          );
        }
        banner = 7;
        return http.Response(
          jsonEncode({'banner_updated_at': 7}),
          200,
          headers: _json,
        );
      case ('DELETE', '/space/banner'):
        banner = null;
        return http.Response('', 204);
      case ('POST', '/space/icon'):
        icon = 9;
        return http.Response(
          jsonEncode({'icon_updated_at': 9}),
          200,
          headers: _json,
        );
      case ('DELETE', '/space/icon'):
        icon = null;
        return http.Response('', 204);
      case ('GET', '/space/icon'):
        return http.Response.bytes(_png, 200);
      case ('GET', '/version'):
        return http.Response(
          jsonEncode({'name': 'Home', 'version': '1', 'protocol': 1}),
          200,
          headers: _json,
        );
      case ('GET', '/members'):
        return http.Response('[]', 200, headers: _json);
      default:
        return http.Response('{}', 404, headers: _json);
    }
  }

  String _settings() => jsonEncode({
    'join_policy': 'invite',
    'totp_policy': 'optional',
    'description': description,
    'banner_updated_at': banner,
    'icon_updated_at': icon,
  });
}

Future<void> _pump(WidgetTester tester, _Server server, double width) async {
  tester.view.physicalSize = Size(width, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final file = FakePlatformFile('b.png', Uint8List.fromList(_png));
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      attachmentPickerProvider.overrideWith(
        (ref, source) =>
            () async => file,
      ),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async => server.handle(request)),
        );
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: SingleChildScrollView(child: InviteLandingSection()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder get _descriptionInput => find.byWidgetPredicate(
  (w) => w is AppInput && w.semanticLabel == 'Description',
);

Finder get _descriptionField =>
    find.descendant(of: _descriptionInput, matching: find.byType(TextField));

Finder _button(String semanticLabel) => find.byWidgetPredicate(
  (w) => w is AppButton && w.semanticLabel == semanticLabel,
);

/// Image decoding finishes on the real clock, so alternate real waiting with
/// pumps until the awaited call has gone out.
Future<void> _untilCalled(
  WidgetTester tester,
  _Server server,
  String call,
) async {
  for (var i = 0; i < 50 && !server.calls.contains(call); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

void main() {
  for (final width in [390.0, 1280.0]) {
    testWidgets(
      'saving a description sends only it and previews it at $width',
      (tester) async {
        final server = _Server();
        await _pump(tester, server, width);
        expect(find.byType(InviteLandingCard), findsOneWidget);
        final save = find.widgetWithText(AppButton, 'Save description');
        expect(tester.widget<AppButton>(save).disabled, isTrue);

        await tester.enterText(_descriptionField, '  A small home server. ');
        await tester.pump();
        expect(find.text('A small home server.'), findsWidgets);
        await tester.tap(save);
        await tester.pumpAndSettle();

        expect(server.lastPatch, {'description': 'A small home server.'});
        expect(tester.widget<AppButton>(save).disabled, isTrue);
        final card = tester.getRect(find.byType(InviteLandingCard));
        expect(card.right, lessThanOrEqualTo(width));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('choosing a banner uploads it and offers to remove it', (
    tester,
  ) async {
    final server = _Server();
    await _pump(tester, server, 390);
    expect(_button('Remove banner'), findsNothing);
    await tester.tap(_button('Choose banner'));
    await _untilCalled(tester, server, 'POST /space/banner');
    expect(server.calls, contains('POST /space/banner'));
    expect(_button('Replace banner'), findsOneWidget);

    await tester.tap(_button('Remove banner'));
    await tester.pumpAndSettle();
    expect(server.calls, contains('DELETE /space/banner'));
    expect(_button('Choose banner'), findsOneWidget);
    expect(find.byType(AspectRatio), findsNothing);
  });

  testWidgets('a refused banner shows a persistent error, not a toast', (
    tester,
  ) async {
    final server = _Server()..uploadStatus = 400;
    await _pump(tester, server, 390);
    await tester.tap(_button('Choose banner'));
    await _untilCalled(tester, server, 'POST /space/banner');
    expect(find.byType(AppErrorState), findsOneWidget);
    expect(_button('Choose banner'), findsOneWidget);
  });

  testWidgets('cancelling the icon crop uploads nothing', (tester) async {
    final server = _Server();
    await _pump(tester, server, 390);
    await tester.tap(_button('Choose icon'));
    await tester.pumpAndSettle();
    expect(find.text('Crop your picture'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(server.calls, isNot(contains('POST /space/icon')));
    expect(_button('Choose icon'), findsOneWidget);
  });

  testWidgets('a cropped icon uploads, previews and can be removed', (
    tester,
  ) async {
    final server = _Server();
    await _pump(tester, server, 1280);
    await tester.tap(_button('Choose icon'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use picture'));
    await _untilCalled(tester, server, 'POST /space/icon');
    expect(server.calls, contains('POST /space/icon'));
    expect(_button('Replace icon'), findsOneWidget);
    expect(find.byType(SpaceIcon), findsOneWidget);

    await tester.tap(_button('Remove icon'));
    await tester.pumpAndSettle();
    expect(server.calls, contains('DELETE /space/icon'));
    expect(_button('Choose icon'), findsOneWidget);
    expect(find.byType(SpaceIcon), findsNothing);
  });

  for (final width in [390.0, 1280.0]) {
    testWidgets(
      'controls share one left edge and rows stay on a line at $width',
      (tester) async {
        final server = _Server()
          ..banner = 7
          ..icon = 9;
        await _pump(tester, server, width);
        final field = tester.getRect(_descriptionInput);
        final inset = field.left + 4;
        final banner = tester.getRect(find.text('Banner'));
        final icon = tester.getRect(find.text('Icon'));
        expect(banner.left, inset);
        expect(icon.left, inset);
        for (final name in ['banner', 'icon']) {
          final choose = tester.getRect(_button('Replace $name'));
          final remove = tester.getRect(_button('Remove $name'));
          expect(remove.top, choose.top);
          expect(remove.right, lessThanOrEqualTo(field.right));
        }
        final save = tester.getRect(
          find.widgetWithText(AppButton, 'Save description'),
        );
        expect(save.right, field.right - 4);
        expect(save.top, greaterThan(field.bottom));
        expect(
          tester.getRect(_button('Replace banner')).left,
          tester.getRect(_button('Replace icon')).left,
        );
      },
    );
  }

  testWidgets('the description field is multi-line', (tester) async {
    await _pump(tester, _Server(), 390);
    final field = tester.widget<TextField>(_descriptionField);
    expect(field.minLines, 2);
    expect(field.maxLines, 4);
  });

  testWidgets('a picture dropped on the banner row uploads like a picked one', (
    tester,
  ) async {
    final server = _Server();
    await _pump(tester, server, 1280);
    final zone = tester.widget<ImageDropZone>(
      find.byWidgetPredicate(
        (w) => w is ImageDropZone && w.label == 'Drop to set the banner',
      ),
    );
    zone.onImage(Uint8List.fromList(_png), 'banner.png');
    await _untilCalled(tester, server, 'POST /space/banner');
    expect(server.calls, contains('POST /space/banner'));
  });

  testWidgets('a refused drop says why in the section', (tester) async {
    await _pump(tester, _Server(), 1280);
    final zone = tester.widget<ImageDropZone>(
      find.byWidgetPredicate(
        (w) => w is ImageDropZone && w.label == 'Drop to set the icon',
      ),
    );
    zone.onRejected('Drop one PNG, JPEG or WebP picture.');
    await tester.pumpAndSettle();
    expect(find.text('Drop one PNG, JPEG or WebP picture.'), findsOneWidget);
    expect(find.byType(AppErrorState), findsOneWidget);
  });

  testWidgets('preview as a visitor shows the joiner\'s view, with Join off', (
    tester,
  ) async {
    await _pump(tester, _Server()..description = 'A small server.', 1280);
    await tester.ensureVisible(find.text('Preview as a visitor'));
    await tester.tap(find.text('Preview as a visitor'));
    await tester.pumpAndSettle();

    final view = find.byType(InviteLandingView);
    expect(view, findsOneWidget);
    expect(
      find.descendant(of: view, matching: find.text('A small server.')),
      findsOneWidget,
    );
    final join = tester.widget<AppButton>(
      find.descendant(
        of: view,
        matching: find.widgetWithText(AppButton, 'Join'),
      ),
    );
    expect(join.disabled, isTrue);
    expect(
      find.text('This is what someone opening one of your invites sees.'),
      findsOneWidget,
    );

    await tester.tap(find.descendant(of: view, matching: find.text('Back')));
    await tester.pumpAndSettle();
    expect(find.byType(InviteLandingView), findsNothing);
  });
}
