// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Troubleshooting row that copies a call report: it works with no call, says so, and carries a live call's numbers.
library;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/toasts.dart';

import '../features/settings/settings_harness.dart';

Future<void> _pumpFrames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<ProviderContainer> _open(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = await pumpPersonalSettings(
    tester,
    0,
    scrollToBottom: false,
  );
  await tester.tap(find.text('Troubleshooting'));
  await _pumpFrames(tester);
  return container;
}

void _captureClipboard(WidgetTester tester, void Function(String) set) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        set((call.arguments as Map)['text'] as String);
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
}

Future<void> _tapCopy(WidgetTester tester) async {
  final row = find.text('Copy call diagnostics');
  await tester.ensureVisible(row);
  await tester.tap(row);
  await _pumpFrames(tester);
}

List<String> _toasts(ProviderContainer container) => [
  for (final toast in container.read(toastsProvider)) toast.message,
];

void _clearToasts(ProviderContainer container) {
  final toasts = container.read(toastsProvider.notifier);
  for (final toast in container.read(toastsProvider)) {
    toasts.dismiss(toast.id);
  }
}

void main() {
  setUpAll(mockAppVersion);

  testWidgets('with no call it copies a report that says so', (tester) async {
    String? copied;
    _captureClipboard(tester, (text) => copied = text);
    final container = await _open(tester);

    await _tapCopy(tester);

    expect(copied, startsWith('Call diagnostics'));
    expect(copied, contains('No call is active, and none has run'));
    expect(copied, contains('Platform:'));
    expect(copied, contains('Microphone: system default'));
    expect(_toasts(container), ['Call diagnostics copied. No call is active.']);
    _clearToasts(container);
  });

  testWidgets('during a call it carries the call numbers', (tester) async {
    String? copied;
    _captureClipboard(tester, (text) => copied = text);
    final container = await _open(tester);
    container.read(voiceControllerProvider.notifier).diagnostics
      ..begin()
      ..noteHealthLine('[voice-health] last 60s | Ann: conceal=0.5%');

    await _tapCopy(tester);

    expect(copied, contains('In a call for'));
    expect(copied, contains('[voice-health] last 60s | Ann: conceal=0.5%'));
    expect(_toasts(container), ['Call diagnostics copied']);
    _clearToasts(container);
  });

  testWidgets('the copy is redacted like the debug log', (tester) async {
    String? copied;
    _captureClipboard(tester, (text) => copied = text);
    final container = await _open(tester);
    container.read(voiceControllerProvider.notifier).diagnostics
      ..begin()
      ..noteHealthLine(
        '[voice-health] last 60s | Authorization: Bearer abc.def.ghi',
      );

    await _tapCopy(tester);

    expect(copied, isNot(contains('abc.def.ghi')));
    _clearToasts(container);
  });
}
