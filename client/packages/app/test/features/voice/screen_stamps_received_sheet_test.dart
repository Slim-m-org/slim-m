// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Pictures on your screen" (decision 0121): each picture with who sent it,
/// Report until it is reported, and plain words for none and for a failure.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/voice/widgets/screen_stamps_received_sheet.dart';

import '../../support/fake_api.dart';

api.ReceivedScreenStamp _stamp(String id, {bool reported = false}) =>
    api.ReceivedScreenStamp(
      id: id,
      channelId: 'call',
      senderId: 'u-$id',
      attachmentId: 'pic-$id',
      createdAt: DateTime.now()
          .subtract(const Duration(minutes: 5))
          .millisecondsSinceEpoch,
      reported: reported,
    );

Future<void> _pump(
  WidgetTester tester,
  Future<List<api.ReceivedScreenStamp>> Function() stamps,
) async {
  await pumpInApp(
    tester,
    const ScreenStampsReceived(),
    settle: false,
    overrides: [
      receivedScreenStampsProvider.overrideWith((ref) => stamps()),
      userProfileProvider.overrideWith(
        (ref, id) async => api.UserProfile.fromJson({
          'id': id,
          'username': id,
          'display_name': 'Sender $id',
          'created_at': 0,
        }),
      ),
    ],
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('each picture names its sender, when, and Report or Reported', (
    tester,
  ) async {
    await _pump(tester, () async => [_stamp('a'), _stamp('b', reported: true)]);
    expect(find.text('Sender u-a'), findsOneWidget);
    expect(find.text('5m ago'), findsNWidgets(2));
    expect(find.text('Report'), findsOneWidget);
    expect(find.text('Reported'), findsOneWidget);
    expect(find.text('Block'), findsNWidgets(2));
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
