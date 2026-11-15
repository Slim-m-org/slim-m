// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The launch splash mounts on every page load, before the routed app, so it
/// must never ask the web engine for a history of its own.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/startup_screen.dart';

void main() {
  testWidgets('the splash leaves the browser history mode alone', (
    tester,
  ) async {
    // A reload in a tab past 50 navigations froze the address bar and then broke every link.
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.navigation,
      (call) async {
        calls.add(call.method);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.navigation,
        null,
      ),
    );

    await tester.pumpWidget(const StartupApp());
    await tester.pump();

    expect(calls, isNot(contains('selectSingleEntryHistory')));
    expect(calls, isNot(contains('routeInformationUpdated')));
  });
}
