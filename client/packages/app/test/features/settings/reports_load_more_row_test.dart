// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The trailing row of a paged moderation list shows the sentence its
/// controller wrote, with a retry beside it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/screens/admin/reports_load_more_row.dart';
import '../../support/fake_api.dart';

void main() {
  testWidgets('a failed page reads as the controller\'s sentence, with a '
      'retry', (tester) async {
    var taps = 0;
    await pumpInApp(
      tester,
      ReportsLoadMoreRow(
        loading: false,
        error: 'Could not load more reports.',
        onTap: () async => taps++,
      ),
    );

    expect(find.text('Could not load more reports.'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('a full page offers Load more', (tester) async {
    await pumpInApp(
      tester,
      ReportsLoadMoreRow(loading: false, error: null, onTap: () async {}),
    );

    expect(find.text('Load more'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });
}
