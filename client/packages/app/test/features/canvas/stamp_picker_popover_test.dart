// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Stamp picker as a popover (decision 0121) keeps one place and size
/// across its tabs, so switching from Emoji to a shorter tab never makes it jump.
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

void main() {
  testWidgets('switching tabs never moves or resizes the popover', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpInApp(
      tester,
      Stack(
        children: [
          Positioned(
            left: 560,
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
        mockApiOverride(_api),
      ],
    );
    await _frames(tester);
    await tester.tap(find.text('Stamp'));
    await _frames(tester);
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
}
