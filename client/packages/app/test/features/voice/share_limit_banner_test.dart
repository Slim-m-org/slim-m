// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sharer is told plainly what is holding their share back, and can wave
/// it away.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/widgets/share_limit_banner.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

Widget _host(ValueNotifier<ShareLimit?> limit, VoidCallback onDismiss) =>
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(
        body: ShareLimitBanner(limit: limit, onDismiss: onDismiss),
      ),
    );

void main() {
  testWidgets('shows nothing until a limit is set', (tester) async {
    final limit = ValueNotifier<ShareLimit?>(null);
    await tester.pumpWidget(_host(limit, () {}));
    expect(find.byType(AppCallout), findsNothing);
  });

  testWidgets('names the computer for a cpu limit', (tester) async {
    final limit = ValueNotifier<ShareLimit?>(ShareLimit.cpu);
    await tester.pumpWidget(_host(limit, () {}));
    expect(find.textContaining('Your computer cannot keep up'), findsOneWidget);
  });

  testWidgets('names the connection for a bandwidth limit', (tester) async {
    final limit = ValueNotifier<ShareLimit?>(ShareLimit.bandwidth);
    await tester.pumpWidget(_host(limit, () {}));
    expect(find.textContaining('Your connection cannot carry'), findsOneWidget);
  });

  testWidgets('appears when the limit is raised and Dismiss calls back', (
    tester,
  ) async {
    final limit = ValueNotifier<ShareLimit?>(null);
    var dismissed = 0;
    await tester.pumpWidget(_host(limit, () => dismissed++));
    limit.value = ShareLimit.cpu;
    await tester.pump();
    await tester.tap(find.text('Dismiss'));
    expect(dismissed, 1);
  });
}
