// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the app tells someone whose microphone will not work, per platform,
/// and that the call and the meter carry it with the OS settings link.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/mic_failure_advice.dart';
import 'package:slimm_app/src/features/voice/providers/mic_failure_providers.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/mic_failure_banner.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

MicAdvice _blocked(TargetPlatform platform) =>
    micAdviceFor(MicFailureReason.permissionDenied, platform: platform)!;

void main() {
  group('micAdviceFor', () {
    test('Windows sends the person to the microphone privacy page', () {
      final advice = _blocked(TargetPlatform.windows);
      expect(
        advice.message,
        'Windows is blocking the microphone. Allow apps to use it in Privacy settings.',
      );
      expect(advice.settings.toString(), 'ms-settings:privacy-microphone');
    });

    test(
      'macOS and iOS open their settings, Android and Linux only explain',
      () {
        expect(
          _blocked(TargetPlatform.macOS).message,
          contains('System Settings > Privacy & Security > Microphone'),
        );
        expect(
          _blocked(TargetPlatform.macOS).settings.toString(),
          contains('Privacy_Microphone'),
        );
        expect(
          _blocked(TargetPlatform.iOS).settings.toString(),
          'app-settings:',
        );
        expect(_blocked(TargetPlatform.android).settings, isNull);
        expect(
          _blocked(TargetPlatform.android).message,
          contains('Settings > Apps > Permissions'),
        );
        expect(_blocked(TargetPlatform.linux).settings, isNull);
        expect(_blocked(TargetPlatform.linux).message, contains('sandbox'));
      },
    );

    test('the browser names the address bar', () {
      final advice = micAdviceFor(
        MicFailureReason.permissionDenied,
        web: true,
      )!;
      expect(advice.message, contains('browser'));
      expect(advice.settings, isNull);
    });

    test('busy, missing and silent have their own words, unknown has none', () {
      expect(
        micAdviceFor(MicFailureReason.busy)!.message,
        contains('Another app'),
      );
      expect(
        micAdviceFor(MicFailureReason.notFound)!.message,
        contains('No microphone'),
      );
      expect(
        micAdviceFor(MicFailureReason.silent)!.message,
        contains('no sound'),
      );
      expect(micAdviceFor(MicFailureReason.unknown), isNull);
    });
  });

  group('MicFailureBanner', () {
    Future<List<Uri>> pump(
      WidgetTester tester,
      MicFailureReason? reason,
    ) async {
      final opened = <Uri>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            micFailureProvider.overrideWith((ref) => Stream.value(reason)),
            micSettingsLauncherProvider.overrideWithValue((uri) async {
              opened.add(uri);
              return true;
            }),
          ],
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: const Scaffold(body: MicFailureBanner()),
          ),
        ),
      );
      await tester.pump();
      return opened;
    }

    testWidgets('says Windows is blocking it and opens the privacy page', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final opened = await pump(tester, MicFailureReason.permissionDenied);

      expect(
        find.textContaining('Windows is blocking the microphone'),
        findsOneWidget,
      );
      await tester.tap(find.text('Open settings'));
      await tester.pump();

      expect(opened.single.toString(), 'ms-settings:privacy-microphone');
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a platform with no settings link offers no button', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      await pump(tester, MicFailureReason.permissionDenied);

      expect(find.textContaining('blocking the microphone'), findsOneWidget);
      expect(find.text('Open settings'), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('nothing shows while the microphone works', (tester) async {
      await pump(tester, null);
      expect(find.byType(AppErrorState), findsNothing);
    });
  });

  group('VoiceController.toggleMicrophone', () {
    final harness = VoiceHarness();
    tearDown(harness.dispose);

    Future<VoiceController> refused(MicFailureReason? reason) async {
      final session = FakeSession(microphoneGranted: false)
        ..micFailure = reason;
      final controller = harness.controllerWith(session, voiceApi());
      await controller.toggleMicrophone();
      return controller;
    }

    test(
      'a named cause is left to the banner instead of a generic error',
      () async {
        final controller = await refused(MicFailureReason.permissionDenied);
        expect(controller.state.error, isNull);
      },
    );

    test('an unnamed refusal keeps the generic error', () async {
      final controller = await refused(MicFailureReason.unknown);
      expect(controller.state.error, contains('Could not'));
    });
  });
}
