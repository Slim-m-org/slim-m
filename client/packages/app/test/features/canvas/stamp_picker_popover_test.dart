// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Stamp picker (decision 0121): as a popover it keeps one place and size
/// across its tabs and takes the keyboard in its search at once; as a phone
/// sheet its search waits for a tap, so no keyboard covers the grid on open.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/widgets/stamp_picker.dart';
import 'package:slimm_app/src/providers/providers.dart';

import '../../support/fake_api.dart';

const _tabs = 'What to stamp';

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: const {'content-type': 'application/json'},
);

Future<http.Response> _api(http.Request request) async =>
    switch (request.url.path) {
      '/version' => _json({
        'name': 'slim-m',
        'version': '0.111.0',
        'protocol': 1,
        'gif_search_enabled': true,
        'capabilities': ['screen_stamps'],
      }),
      '/gifs/trending' => _json({'results': <Object>[]}),
      _ => http.Response('{}', 404),
    };

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

/// One trending GIF, whose pick answers with an attachment and records the request.
Future<http.Response> Function(http.Request) _withGif(
  List<http.Request> seen,
) => (request) async {
  seen.add(request);
  return switch (request.url.path) {
    '/gifs/trending' => _json({
      'results': [
        {'id': 'tok', 'title': 'a cat', 'width': 100, 'height': 100},
      ],
    }),
    '/gifs/preview/tok' => http.Response.bytes(
      _gif,
      200,
      headers: const {'content-type': 'image/gif'},
    ),
    '/gifs/select' => http.Response(
      jsonEncode({
        'id': 'att',
        'filename': 'cat.gif',
        'content_type': 'image/gif',
        'size': _gif.length,
      }),
      201,
      headers: const {'content-type': 'application/json'},
    ),
    _ => _api(request),
  };
};

/// A 1x1 GIF.
final _gif = base64Decode(
  'R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==',
);

/// Opens the picker from a Stamp button on a window [width] wide.
Future<void> _open(
  WidgetTester tester,
  double width, {
  Future<http.Response> Function(http.Request) handler = _api,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await pumpInApp(
    tester,
    Stack(
      children: [
        Positioned(
          left: width / 2 - 80,
          bottom: 160,
          child: Builder(
            builder: (anchor) => TextButton(
              onPressed: () => showStampPicker(anchor, onPicked: (_) {}),
              child: const Text('Stamp'),
            ),
          ),
        ),
      ],
    ),
    settle: false,
    overrides: [
      sessionProvider.overrideWithValue(
        api.SessionStore(
          tokens: const api.TokenPair(
            userId: 'me',
            accessToken: 'a',
            refreshToken: 'r',
            accessExpiresAt: 9999999999999,
          ),
        ),
      ),
      mockApiOverride(handler),
    ],
  );
  await _frames(tester);
  await tester.tap(find.text('Stamp'));
  await _frames(tester);
}

void main() {
  testWidgets('switching tabs never moves or resizes the popover', (
    tester,
  ) async {
    await _open(tester, 1280);
    final strip = find.bySemanticsLabel(_tabs);
    final onEmoji = tester.getRect(strip);
    final bottom = tester.getBottomLeft(find.text('Search emoji')).dy;

    final placed = <String, Rect>{};
    for (final tab in const ['Picture', 'GIFs', 'Emoji']) {
      await tester.tap(find.text(tab).last);
      await _frames(tester);
      placed[tab] = tester.getRect(strip);
    }

    expect(placed, {'Picture': onEmoji, 'GIFs': onEmoji, 'Emoji': onEmoji});
    expect(
      tester.getBottomLeft(find.text('Search emoji')).dy,
      bottom,
      reason: 'back on Emoji the body sits where it opened',
    );
  });

  testWidgets('a phone sheet leaves the emoji search for a tap', (
    tester,
  ) async {
    await _open(tester, 390);

    expect(find.text('Search emoji'), findsOneWidget);
    expect(
      tester.testTextInput.hasAnyClients,
      isFalse,
      reason: 'no keyboard rises over the grid on open',
    );
  });

  testWidgets('a popover puts the keyboard in the emoji search at once', (
    tester,
  ) async {
    await _open(tester, 1280);

    expect(tester.testTextInput.hasAnyClients, isTrue);
  });

  testWidgets('a GIF picked for a stamp asks for one small enough to place', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final seen = <http.Request>[];
    await _open(tester, 1280, handler: _withGif(seen));
    await tester.tap(find.text('GIFs').last);
    await _frames(tester);
    await tester.tap(find.bySemanticsLabel('Pick: a cat'));
    await _frames(tester);

    final select = seen.singleWhere((r) => r.url.path == '/gifs/select');
    expect(jsonDecode(select.body), containsPair('for_stamp', true));
    handle.dispose();
  });
}
