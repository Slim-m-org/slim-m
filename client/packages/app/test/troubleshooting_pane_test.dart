// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The debug log as an inner page of the Troubleshooting pane on a wide
/// window: a breadcrumb heading, the log's actions, a severity filter and the
/// memory readout, with the way back to the pane.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/diagnostics/debug_log.dart';
import 'package:slimm_app/src/providers/toasts.dart';
import 'package:slimm_design_system/design_system.dart';

import 'features/settings/settings_harness.dart';

Future<ProviderContainer> _open(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = await pumpPersonalSettings(
    tester,
    0,
    scrollToBottom: false,
  );
  container.read(debugLogProvider.notifier)
    ..record('flutter', 'overflowed')
    ..record('voice', 'slow', level: DiagnosticSeverity.warning)
    ..record('voice', 'reconnected', level: DiagnosticSeverity.info);
  await tester.tap(find.text('Troubleshooting'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Debug log'));
  await tester.pumpAndSettle();
  return container;
}

void main() {
  setUpAll(mockAppVersion);

  testWidgets('the row opens the log beside the nav with a breadcrumb', (
    tester,
  ) async {
    await _open(tester);

    expect(find.text('Troubleshooting'), findsNWidgets(2));
    expect(find.text('Debug log'), findsOneWidget);
    expect(find.text('Copy all'), findsOneWidget);
    expect(find.text('Clear'), findsOneWidget);
    expect(find.text('Device check'), findsNothing);

    await tester.tap(find.byTooltip('Back to troubleshooting'));
    await tester.pumpAndSettle();
    expect(find.text('Device check'), findsOneWidget);
  });

  testWidgets('the filter narrows the list and counts each level', (
    tester,
  ) async {
    await _open(tester);

    expect(find.text('All 3'), findsOneWidget);
    expect(find.text('Errors 1'), findsOneWidget);
    expect(find.text('Warnings 1'), findsOneWidget);

    await tester.tap(find.text('Errors 1'));
    await tester.pumpAndSettle();
    expect(find.text('overflowed'), findsOneWidget);
    expect(find.text('reconnected'), findsNothing);
  });

  testWidgets('Copy all puts every entry on the clipboard', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final container = await _open(tester);

    await tester.tap(find.text('Copy all'));
    await tester.pumpAndSettle();

    expect(copied, allOf(contains('overflowed'), contains('reconnected')));
    final toasts = container.read(toastsProvider.notifier);
    for (final toast in container.read(toastsProvider)) {
      toasts.dismiss(toast.id);
    }
  });

  testWidgets('clear empties the log and shows the all-clear state', (
    tester,
  ) async {
    await _open(tester);

    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();

    expect(find.text('Nothing has gone wrong this session'), findsOneWidget);
    expect(find.byIcon(AppIcons.check), findsOneWidget);
  });

  testWidgets('memory shows a bar under each capped value', (tester) async {
    await _open(tester);

    expect(find.text('Image cache'), findsOneWidget);
    expect(find.byType(FractionallySizedBox), findsNWidgets(2));
  });
}
