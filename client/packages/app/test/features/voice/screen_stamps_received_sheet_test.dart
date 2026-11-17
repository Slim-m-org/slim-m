// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Pictures on your screen" (decision 0121): one row per sender with their
/// latest picture and how many they sent, Report until it is reported, a row
/// that opens that sender's own pictures, and plain words for none and a failure.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/voice/widgets/screen_stamps_received_sheet.dart';
import 'package:slimm_app/src/providers/providers.dart';

import '../../support/fake_api.dart';
import '../../support/toast_host.dart';

final _fiveMinutesAgo = DateTime.now()
    .subtract(const Duration(minutes: 5))
    .millisecondsSinceEpoch;

api.ReceivedScreenStamp _stamp(
  String id,
  String sender, {
  bool reported = false,
}) => api.ReceivedScreenStamp(
  id: id,
  channelId: 'call',
  senderId: sender,
  attachmentId: 'pic-$id',
  createdAt: _fiveMinutesAgo,
  reported: reported,
);

api.ScreenStampSender _sender(
  String id, {
  int count = 1,
  bool reported = false,
}) => api.ScreenStampSender(
  senderId: 'u-$id',
  count: count,
  reported: reported,
  latest: _stamp('latest-$id', 'u-$id', reported: reported),
);

Future<void> _pump(
  WidgetTester tester,
  Future<List<api.ScreenStampSender>> Function() senders, {
  List<api.ReceivedScreenStamp> pictures = const [],
  List<Map<String, dynamic>>? reports,
}) async {
  SharedPreferences.setMockInitialValues({});
  await pumpInApp(
    tester,
    const ScreenStampsReceived(),
    settle: false,
    overrides: [
      receivedScreenStampsProvider.overrideWith((ref) => senders()),
      receivedScreenStampsFromProvider.overrideWith(
        (ref, senderId) async =>
            pictures.where((p) => p.senderId == senderId).toList(),
      ),
      userProfileProvider.overrideWith(
        (ref, id) async => api.UserProfile.fromJson({
          'id': id,
          'username': id,
          'display_name': 'Sender $id',
          'created_at': 0,
        }),
      ),
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
      mockApiOverride((request) async {
        if (request.method == 'POST' && request.url.path == '/reports') {
          reports?.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response(
            jsonEncode({'id': 'r1'}),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 404);
      }),
    ],
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

void main() {
  testWidgets(
    'each sender shows how many they sent, when, and Report or Reported',
    (tester) async {
      await _pump(
        tester,
        () async => [_sender('a', count: 3), _sender('b', reported: true)],
      );
      expect(find.text('Sender u-a'), findsOneWidget);
      expect(find.text('3 pictures · 5m ago'), findsOneWidget);
      expect(find.text('1 picture · 5m ago'), findsOneWidget);
      expect(find.text('Report'), findsOneWidget);
      expect(find.text('Reported'), findsOneWidget);
      expect(find.text('Block'), findsNWidgets(2));
    },
  );

  testWidgets("a sender's row opens their pictures, and Back returns", (
    tester,
  ) async {
    await _pump(
      tester,
      () async => [_sender('a', count: 2), _sender('b')],
      pictures: [
        _stamp('s2', 'u-a'),
        _stamp('s1', 'u-a'),
        _stamp('other', 'u-b'),
      ],
    );

    await tester.tap(find.text('Sender u-a'));
    await _frames(tester);

    expect(find.text('Sender u-a'), findsOneWidget);
    expect(find.bySemanticsLabel('Back to everyone'), findsOneWidget);
    expect(find.text('2 pictures in the last day.'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Picture from Sender u-a, 5m ago'),
      findsNWidgets(2),
    );
    expect(find.text('Sender u-b'), findsNothing);
    expect(find.text('Report'), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await _frames(tester);

    expect(find.text('Pictures on your screen'), findsOneWidget);
    expect(find.text('Sender u-b'), findsOneWidget);
  });

  testWidgets('Report files about the sender by naming their latest picture', (
    tester,
  ) async {
    final reports = <Map<String, dynamic>>[];
    await _pump(tester, () async => [_sender('a', count: 4)], reports: reports);

    await tester.tap(find.text('Report'));
    await _frames(tester);
    tester.testTextInput.enterText('spam');
    await tester.pump();
    await tester.tap(find.text('Report').last);
    await _frames(tester);

    expect(reports, hasLength(1));
    expect(
      (reports.single['subject_kind'], reports.single['subject_id']),
      ('screen_stamp', 'latest-a'),
    );
    await expireToasts(tester);
  });

  testWidgets('none in the last day says so', (tester) async {
    await _pump(tester, () async => const []);
    expect(find.text('No pictures in the last day.'), findsOneWidget);
  });

  testWidgets('a failed load offers a retry', (tester) async {
    await _pump(tester, () async => throw const api.TransportException('down'));
    expect(find.text('Could not load the pictures.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}
