// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [AppHaptics] reaches the platform only on a phone with haptics switched on,
/// and each cue maps to its own engine call.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <String>[];

  setUp(() {
    calls.clear();
    AppHaptics.enabled = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        calls.add(call.arguments as String);
      }
      return null;
    });
  });

  tearDown(() {
    AppHaptics.enabled = true;
    debugDefaultTargetPlatformOverride = null;
  });

  test('each cue maps to its own engine call on a phone', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AppHaptics.selection();
    AppHaptics.impact();
    AppHaptics.success();
    AppHaptics.warning();
    expect(calls, [
      'HapticFeedbackType.selectionClick',
      'HapticFeedbackType.lightImpact',
      'HapticFeedbackType.mediumImpact',
      'HapticFeedbackType.heavyImpact',
    ]);
  });

  test('switching haptics off silences every cue', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    AppHaptics.enabled = false;
    AppHaptics.selection();
    AppHaptics.impact();
    AppHaptics.success();
    AppHaptics.warning();
    expect(calls, isEmpty);
  });

  test('a desktop never reaches the platform channel', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    AppHaptics.selection();
    AppHaptics.success();
    expect(calls, isEmpty);
  });
}
