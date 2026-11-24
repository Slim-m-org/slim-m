// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A local-store failure after a delete reached the server still ends the
/// card's busy state and says so, rather than leaving every button dead.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';
import '../settings/report_card_harness.dart';

void main() {
  testWidgets('a StateError in delete message clears busy and shows an error', (
    tester,
  ) async {
    await pumpReports(
      tester,
      reports: [
        reportJson(
          id: 'r1',
          subjectKind: 'message',
          subjectId: 'm1',
          channelId: 'c1',
          channelPermissions: Perm.manageMessages,
        ),
      ],
      overrides: [
        storeProvider.overrideWith((ref) async => throw StateError('store')),
      ],
    );

    await tester.tap(find.widgetWithText(AppButton, 'Delete message'));
    await pumpFrames(tester);
    await tester.tap(find.widgetWithText(AppButton, 'Delete'));
    await pumpFrames(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('Could not delete the message.'), findsOneWidget);
    expect(find.textContaining('StateError'), findsNothing);
    expect(
      tester
          .widget<AppButton>(find.widgetWithText(AppButton, 'Delete message'))
          .disabled,
      isFalse,
    );
  });
}
