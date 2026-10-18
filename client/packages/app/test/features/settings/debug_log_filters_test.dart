// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The debug log screen's filters: level, tag, free-text search, and a copy
/// that exports exactly what is shown, redacted.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/diagnostics/debug_log.dart';
import 'package:slimm_app/src/diagnostics/debug_log_filter.dart';
import 'package:slimm_app/src/features/settings/screens/debug_log_screen.dart';
import 'package:slimm_design_system/design_system.dart';

DebugLog _log() {
  LogRecord at(LogLevel level, String tag, String message) => LogRecord(
    at: DateTime(2026, 10, 18),
    level: level,
    tag: tag,
    message: message,
    context: const {},
  );
  return DebugLog()
    ..write(at(LogLevel.error, LogTag.sync, 'sync dropped'))
    ..write(at(LogLevel.warning, LogTag.push, 'push refused password=pw123'))
    ..write(at(LogLevel.info, LogTag.voice, 'voice joined'))
    ..write(at(LogLevel.debug, LogTag.voice, 'voice stats'));
}

Future<ProviderContainer> _open(
  WidgetTester tester, {
  double width = 900,
}) async {
  tester.view.physicalSize = Size(width, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final log = _log();
  final container = ProviderContainer(
    overrides: [debugLogProvider.overrideWith((ref) => log)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const DebugLogScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('the level control filters and counts each level', (
    tester,
  ) async {
    await _open(tester);
    expect(find.text('All 4'), findsOneWidget);
    expect(find.text('Debug 1'), findsOneWidget);

    await tester.tap(find.text('Debug 1'));
    await tester.pumpAndSettle();
    expect(find.text('voice stats'), findsOneWidget);
    expect(find.text('sync dropped'), findsNothing);

    await tester.tap(find.text('Errors 1'));
    await tester.pumpAndSettle();
    expect(find.text('sync dropped'), findsOneWidget);
    expect(find.text('voice stats'), findsNothing);
  });

  testWidgets('an area chip narrows to that area and a second tap clears it', (
    tester,
  ) async {
    await _open(tester);
    await tester.tap(find.byKey(const ValueKey('area-voice')));
    await tester.pumpAndSettle();
    expect(find.text('voice joined'), findsOneWidget);
    expect(find.text('sync dropped'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('area-voice')));
    await tester.pumpAndSettle();
    expect(find.text('sync dropped'), findsOneWidget);
  });

  testWidgets('search matches message text and says when nothing matches', (
    tester,
  ) async {
    await _open(tester);
    await tester.enterText(find.byType(EditableText).first, 'JOINED');
    await tester.pumpAndSettle();
    expect(find.text('voice joined'), findsOneWidget);
    expect(find.text('sync dropped'), findsNothing);

    await tester.enterText(find.byType(EditableText).first, 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('Nothing matches this filter.'), findsOneWidget);
  });

  testWidgets('copy exports only what is shown, with secrets redacted', (
    tester,
  ) async {
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
    await _open(tester);

    await tester.tap(find.text('Warnings 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Copy shown'));
    await tester.pumpAndSettle();

    expect(copied, contains('push refused'));
    expect(copied, isNot(contains('pw123')));
    expect(copied, isNot(contains('sync dropped')));
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('the filters lay out at phone width without overflowing', (
    tester,
  ) async {
    await _open(tester, width: 390);
    expect(tester.takeException(), isNull);
    expect(find.text('Warnings 1'), findsOneWidget);
  });

  test('the filter matches level, tag and query together', () {
    final events = _log().state;
    const f = DebugLogFilter();
    expect(f.apply(events), hasLength(4));
    expect(f.withTag(LogTag.voice).apply(events), hasLength(2));
    expect(
      f.withTag(LogTag.voice).withLevel(LogLevel.debug).apply(events),
      hasLength(1),
    );
    expect(f.withQuery('PUSH').apply(events), hasLength(1));
  });
}
