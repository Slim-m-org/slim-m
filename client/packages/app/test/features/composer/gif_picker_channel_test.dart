// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A picker opened for a channel names it on every gif request, so a channel
/// overwrite granting ATTACH_FILES is honoured by the server.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/composer/widgets/gif_picker.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _channel = '0190a7f0-0000-7000-8000-000000000001';

final _gif = base64Decode(
  'R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==',
);

Map<String, Object?> _result(String id) => {
  'id': id,
  'title': 'a cat',
  'width': 100,
  'height': 100,
};

Future<List<http.BaseRequest>> _pump(
  WidgetTester tester, {
  String? channelId,
}) async {
  final seen = <http.BaseRequest>[];
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      mockApiOverride((request) async {
        seen.add(request);
        final path = request.url.path;
        if (path == '/gifs/trending' || path == '/gifs/search') {
          return http.Response(
            jsonEncode({
              'results': [_result('tok')],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path == '/gifs/preview/tok') {
          return http.Response.bytes(
            _gif,
            200,
            headers: {'content-type': 'image/gif'},
          );
        }
        if (path == '/gifs/select') {
          return http.Response(
            jsonEncode({
              'id': 'att',
              'filename': 'gif.gif',
              'content_type': 'image/gif',
              'size': _gif.length,
            }),
            201,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('unexpected $path', 500);
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: GifPickerBody(channelId: channelId, onPicked: (_) {}),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return seen;
}

void main() {
  testWidgets('trending, preview, search and select all carry the channel', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final seen = await _pump(tester, channelId: _channel);

    await tester.enterText(find.byType(TextField), 'cat');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Pick: a cat'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    for (final path in [
      '/gifs/trending',
      '/gifs/search',
      '/gifs/preview/tok',
    ]) {
      final request = seen.firstWhere((r) => r.url.path == path);
      expect(request.url.queryParameters['channel_id'], _channel, reason: path);
    }
    final select = seen.firstWhere((r) => r.url.path == '/gifs/select');
    final body = jsonDecode((select as http.Request).body) as Map;
    expect(body['channel_id'], _channel);
    handle.dispose();
  });

  testWidgets('without a channel no request names one', (tester) async {
    final seen = await _pump(tester);
    expect(
      seen.where((r) => r.url.queryParameters.containsKey('channel_id')),
      isEmpty,
    );
  });
}
