// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The picker's Favorites tab: it leads once there are favorites, sends on
/// tap, answers an unavailable one gracefully, and reorders by drag on a wide
/// window and through the long-press menu on a narrow one.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/composer/widgets/gif_picker.dart';
import 'package:slimm_app/src/features/favorites/providers/favorites_controller.dart';
import 'package:slimm_app/src/features/messages/providers/attachment_preview_bytes.dart';
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

Map<String, Object?> _gif(String id, {bool available = true}) => {
  'id': id,
  'kind': 'gif',
  'title': 'gif $id',
  'width': 100,
  'height': 100,
  'available': available,
  'created_at': 1,
};

Map<String, Object?> _kept(String id, {required bool available}) => {
  'id': id,
  'kind': 'attachment',
  'title': 'photo.png',
  'width': 0,
  'height': 0,
  'available': available,
  'created_at': 1,
  'attachment_id': 'ab' * 32,
  'content_type': 'image/png',
  if (available) 'message_id': 'm1',
  if (available) 'channel_id': 'c1',
};

class _Server {
  _Server(this.favorites);

  List<Map<String, Object?>> favorites;
  final calls = <String>[];
  Object? lastBody;
  int selectStatus = 201;
  bool failOrder = false;

  Future<http.Response> handle(http.Request request) async {
    final call = '${request.method} ${request.url.path}';
    calls.add(call);
    http.Response json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );
    if (request.body.isNotEmpty) lastBody = jsonDecode(request.body);
    return switch (call) {
      'GET /favorites' => json(favorites),
      'GET /gifs/trending' => json({
        'results': [
          {'id': 'tok-1', 'title': 'a cat', 'width': 10, 'height': 10},
        ],
      }),
      'PUT /favorites/order' when failOrder => json({'error': 'nope'}, 400),
      'PUT /favorites/order' => http.Response('', 204),
      'POST /favorites' => json(_gif('new1'), 201),
      _ when request.method == 'DELETE' => http.Response('', 204),
      _ when call.endsWith('/select') && selectStatus == 409 => json({
        'error': 'that favorite is no longer available',
      }, 409),
      _ when call.endsWith('/select') => json({
        'id': 'ff' * 32,
        'filename': 'sent.gif',
        'content_type': 'image/gif',
        'size': 5,
      }, selectStatus),
      _ when call.endsWith('/preview') || call.contains('/gifs/preview/') =>
        http.Response.bytes(_png, 200, headers: {'content-type': 'image/png'}),
      _ => http.Response('unexpected $call', 500),
    };
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Server server, {
  required void Function(api.Attachment) onPicked,
  Size size = const Size(800, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      mockApiOverride(server.handle),
      attachmentPreviewBytesProvider.overrideWith((ref, key) async => _png),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: GifPickerBody(onPicked: onPicked)),
      ),
    ),
  );
  await _until(tester, () => container.read(favoritesProvider).hasValue);
  return container;
}

/// Polls model state in real time, pumping between polls; spinners never settle.
Future<void> _until(WidgetTester tester, bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!done() && DateTime.now().isBefore(deadline)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(done(), isTrue, reason: 'the condition never became true');
  await tester.pump(const Duration(milliseconds: 100));
}

Finder _tile(String id) => find.byKey(ValueKey('favorite-$id'));

void main() {
  testWidgets('Favorites leads when there are any, and a tap sends it', (
    tester,
  ) async {
    final server = _Server([_gif('a'), _gif('b')]);
    api.Attachment? picked;
    final container = await _pump(tester, server, onPicked: (a) => picked = a);

    expect(find.text('Favorites'), findsOneWidget);
    expect(find.text('Search GIFs'), findsNothing);
    await tester.tap(_tile('a'));
    await _until(tester, () => picked != null);

    expect(server.calls, contains('POST /favorites/a/select'));
    expect(picked!.id, 'ff' * 32);
    expect(container.read(favoritesProvider).requireValue, hasLength(2));
  });

  testWidgets('the GIFs tab is still reachable and the search field is back', (
    tester,
  ) async {
    final server = _Server([_gif('a')]);
    await _pump(tester, server, onPicked: (_) {});

    await tester.tap(find.text('GIFs'));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Search GIFs'), findsOneWidget);
    expect(_tile('a'), findsNothing);
  });

  testWidgets('an unavailable favorite cannot be sent', (tester) async {
    final server = _Server([_kept('k', available: false)]);
    api.Attachment? picked;
    await _pump(tester, server, onPicked: (a) => picked = a);

    expect(find.text('Unavailable'), findsOneWidget);
    await tester.tap(_tile('k'));
    await tester.pump(const Duration(milliseconds: 50));

    expect(picked, isNull);
    expect(server.calls.where((c) => c.endsWith('/select')), isEmpty);
  });

  testWidgets('a favorite that went away mid-pick says so and reloads', (
    tester,
  ) async {
    final server = _Server([_kept('k', available: true)])..selectStatus = 409;
    await _pump(tester, server, onPicked: (_) {});

    await tester.tap(_tile('k'));
    await _until(
      tester,
      () => server.calls.where((c) => c == 'GET /favorites').length == 2,
    );

    expect(find.text('That favorite is no longer available.'), findsOneWidget);
  });

  testWidgets('a wide window reorders by dragging a tile onto another', (
    tester,
  ) async {
    final server = _Server([_gif('a'), _gif('b'), _gif('c')]);
    await _pump(tester, server, onPicked: (_) {});

    final from = tester.getCenter(_tile('a'));
    final to = tester.getCenter(_tile('c'));
    final gesture = await tester.startGesture(from);
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    await gesture.moveTo(to);
    await tester.pump();
    await gesture.up();
    await _until(tester, () => server.calls.contains('PUT /favorites/order'));

    expect((server.lastBody! as Map)['ids'], ['b', 'c', 'a']);
  });

  testWidgets('a narrow window reorders and removes through the menu', (
    tester,
  ) async {
    final server = _Server([_gif('a'), _gif('b')]);
    await _pump(tester, server, onPicked: (_) {}, size: const Size(390, 844));

    await tester.longPress(_tile('a'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Move earlier'), findsNothing, reason: 'already first');
    await tester.tap(find.text('Move later'));
    await _until(tester, () => server.calls.contains('PUT /favorites/order'));
    expect((server.lastBody! as Map)['ids'], ['b', 'a']);

    await tester.longPress(_tile('a'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Remove from favorites'));
    await _until(tester, () => server.calls.contains('DELETE /favorites/a'));

    expect(_tile('a'), findsNothing);
  });

  testWidgets('right-clicking a search result adds it to favorites', (
    tester,
  ) async {
    final server = _Server([]);
    final container = await _pump(tester, server, onPicked: (_) {});
    await _until(tester, () => server.calls.contains('GET /gifs/trending'));

    final tile = find.bySemanticsLabel('Pick: a cat');
    await tester.tap(tile, buttons: kSecondaryButton);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Add to favorites'));
    await _until(tester, () => server.calls.contains('POST /favorites'));

    await tester.pump(const Duration(seconds: 5));
    expect((server.lastBody! as Map)['gif_id'], 'tok-1');
    expect(container.read(favoritesProvider).requireValue.first.id, 'new1');
  });

  testWidgets('a reorder the server refuses puts the list back and says so', (
    tester,
  ) async {
    final server = _Server([_gif('a'), _gif('b')])..failOrder = true;
    final container = await _pump(
      tester,
      server,
      onPicked: (_) {},
      size: const Size(390, 844),
    );

    await tester.longPress(_tile('a'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Move later'));
    await _until(tester, () => server.calls.contains('PUT /favorites/order'));

    final ids = container.read(favoritesProvider).requireValue.map((f) => f.id);
    expect(ids, ['a', 'b']);
    expect(find.textContaining('reorder your favorites'), findsOneWidget);
  });
}
