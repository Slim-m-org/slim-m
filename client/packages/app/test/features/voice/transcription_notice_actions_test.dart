// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The notice check fails closed: a read that fails is owed, never skipped.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/transcription_notice.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

void main() {
  late TranscriptionNoticeActions actions;

  setUp(() {
    final client = testApi((_) async => http.Response('{}', 500));
    addTearDown(client.close);
    actions = TranscriptionNoticeActions(client);
  });

  test('an unreadable notice counts as due', () async {
    expect(await actions.isDue(), isTrue);
  });

  TranscriptionNoticeActions answering(int status) {
    final client = testApi((_) async => http.Response('{}', status));
    addTearDown(client.close);
    return TranscriptionNoticeActions(client);
  }

  test('a server without the route owes no notice', () async {
    final old = answering(404);
    expect(await old.dueNotice(), isNull);
    expect(await old.isDue(), isFalse);
  });

  test('a server that is down still owes the notice', () async {
    final down = answering(503);
    expect(await down.isDue(), isTrue);
    await expectLater(down.dueNotice(), throwsA(isA<api.ApiException>()));
  });

  test('an unreadable notice is an error, not "nothing due"', () async {
    await expectLater(actions.dueNotice(), throwsA(isA<api.ApiException>()));
  });
}
