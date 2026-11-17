// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A report about pictures stamped on someone's screen (decision 0121) names
/// the person who sent them and offers nothing that needs a stored message.
library;

import 'package:flutter_test/flutter_test.dart';

import '../settings/report_card_harness.dart';

void main() {
  testWidgets('a screen stamp report shows who sent the pictures', (
    tester,
  ) async {
    await pumpReports(
      tester,
      reports: [
        reportJson(
          id: 'report-1',
          subjectKind: 'screen_stamp',
          subjectId: 'viewer-1',
          reporterId: 'sharer-1',
          channelId: 'channel-1',
          subjectAuthorId: 'viewer-1',
          channelPermissions: -1,
        ),
      ],
      profiles: {'sharer-1': 'Alice', 'viewer-1': 'Bob'},
    );

    expect(find.text('Reported pictures'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Jump to message'), findsNothing);
    expect(find.text('Delete message'), findsNothing);
  });

  testWidgets('the pictures are shown beside the reason while kept', (
    tester,
  ) async {
    await pumpReports(
      tester,
      reports: [
        reportJson(
          id: 'report-1',
          subjectKind: 'screen_stamp',
          subjectId: 'viewer-1',
          reporterId: 'sharer-1',
          channelId: 'channel-1',
          subjectAuthorId: 'viewer-1',
          channelPermissions: -1,
          pictureIds: const ['pic-1', 'pic-2'],
        ),
      ],
      profiles: {'sharer-1': 'Alice', 'viewer-1': 'Bob'},
    );

    expect(find.text("Stamped on Alice's shared screen"), findsOneWidget);
    expect(find.bySemanticsLabel('Reported picture'), findsNWidgets(2));
  });
}
