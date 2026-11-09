// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A typed `/app` launch that is sent again after a lost reply: the text
/// stays in the field for exactly that retry, so it carries the first
/// attempt's id; once a launch lands, typing it again is a new launch.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/modules/providers/app_launch.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart' as data;
import 'package:slimm_test_support/slimm_test_support.dart';

import '../../support/async_wait.dart';
import 'composer_harness.dart';

const _app = api.App(
  moduleId: 'mod-1',
  command: 'whiteboard',
  name: 'Whiteboard',
  description: 'Draw together',
);

void main() {
  testWidgets('a retried /app launch keeps its id until one lands', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final db = data.SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final posts = <Map<String, dynamic>>[];
    var dropNextReply = true;
    api.SlimmApi apiBuilder(Ref ref) => testApi((request) async {
      if (request.url.path != '/channels/c1/messages/apps') {
        return http.Response('{}', 404);
      }
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      posts.add(body);
      if (dropNextReply) {
        dropNextReply = false;
        throw http.ClientException('connection closed');
      }
      return http.Response(
        jsonEncode({
          'id': body['id'],
          'channel_id': 'c1',
          'author_id': 'self',
          'author_display_name': 'Me',
          'seq': posts.length,
          'content': '',
          'created_at': 1000,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }, session: ref.watch(sessionProvider));
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: Sends(),
        platform: TargetPlatform.linux,
        apiBuilder: apiBuilder,
        extraOverrides: [
          storeProvider.overrideWith((ref) async => data.MessageStore(db)),
          appLaunchProvider.overrideWith((ref) async => const [_app]),
        ],
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    Future<void> launch() async {
      final before = posts.length;
      await tester.enterText(
        find.byWidgetPredicate((w) => w is TextField),
        '/whiteboard now',
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await waitUntil(tester, () => posts.length > before);
    }

    await launch();
    expect(controller.text, '/whiteboard now', reason: 'kept for the retry');
    await launch();
    expect(controller.text, isEmpty);
    await launch();

    // Unmounted here so drift's stream-close timer fires inside the test.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 10));

    final ids = [for (final p in posts) p['id']];
    expect(ids, hasLength(3));
    expect(ids[1], ids[0], reason: 'the retry replays the first launch');
    expect(ids[2], isNot(ids[0]), reason: 'a launch that landed is done');
  });
}
