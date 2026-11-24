// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The share menu's "Sharing" submenu says when it is still listing screens,
/// when listing them failed, and when there is nothing to share.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_call_controls_harness.dart';

const _sharing = VoiceFlags(
  state: VoiceSessionState.connected,
  screenSharing: true,
);

Future<void> _openSharing(
  WidgetTester tester,
  Future<List<ScreenShareSource>> sources,
) async {
  await pumpControls(
    tester,
    _sharing,
    session: InertSession(needsSource: true, sources: sources),
  );
  await tester.tap(find.byTooltip('Screen share options'));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(find.text('Sharing'));
  await tester.pump(const Duration(milliseconds: 400));
}

final _spinner = find.byWidgetPredicate((w) => w is AppSpinner);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a slow listing shows a spinner, then the screens', (
    tester,
  ) async {
    final sources = Completer<List<ScreenShareSource>>();
    await _openSharing(tester, sources.future);
    expect(_spinner, findsOneWidget);

    sources.complete(const [ScreenShareSource(id: '1', name: 'Screen 1')]);
    await tester.pump(const Duration(milliseconds: 100));

    expect(_spinner, findsNothing);
    expect(find.text('Screen 1'), findsOneWidget);
  });

  testWidgets('a failed listing says so instead of showing nothing', (
    tester,
  ) async {
    final failed = Future<List<ScreenShareSource>>.error(
      StateError('no portal'),
    )..ignore();
    await _openSharing(tester, failed);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Could not list your screens.'), findsOneWidget);
    expect(_spinner, findsNothing);
  });

  testWidgets('an empty listing says there is nothing to share', (
    tester,
  ) async {
    await _openSharing(tester, Future.value(const <ScreenShareSource>[]));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Nothing to share.'), findsOneWidget);
  });
}
