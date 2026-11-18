// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A file refused for its size never reaches the tray, so the sentence saying
/// so is its only trace: it stays until dismissed or the next pick, never
/// fading on a timer, and the limit it names is the one `/version` holds now.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

import 'composer_harness.dart';

api.SlimmApi Function(Ref) _server(int maxBytes, List<String> uploads) =>
    (ref) => testApi((request) async {
      if (request.url.path == '/version') {
        return http.Response(
          jsonEncode({
            'name': 'slim-m',
            'version': '1.0.0',
            'protocol': 1,
            'max_attachment_bytes': maxBytes,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/attachments') uploads.add(request.method);
      return http.Response('{}', 404, headers: {'content-type': 'text/plain'});
    }, session: ref.watch(sessionProvider));

void main() {
  late TextEditingController controller;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controller = TextEditingController();
  });

  tearDown(() => controller.dispose());

  testWidgets('a size refusal stays until it is dismissed', (tester) async {
    final uploads = <String>[];
    usePicker(FakePlatformFile('scan.pdf', Uint8List(4000)));
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: Sends(),
        platform: TargetPlatform.linux,
        apiBuilder: _server(1024, uploads),
      ),
    );
    await tester.pump();

    await tester.tap(attachButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final refusal = find.textContaining('scan.pdf is 3.9 KB, over');
    expect(refusal, findsOneWidget);

    await tester.pump(const Duration(seconds: 30));
    expect(refusal, findsOneWidget, reason: 'nothing else says it was refused');
    expect(uploads, isEmpty);

    await tester.tap(find.text('Dismiss'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(refusal, findsNothing);
  });
}
