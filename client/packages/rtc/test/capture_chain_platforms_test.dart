// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which hosts run the fork's capture chain, and the settings the browser's
/// worklet is handed.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/src/input_gate.dart';
import 'package:slimm_rtc/src/web_capture_chain_settings.dart';

void main() {
  group('captureChainRunsOn', () {
    test('desktop, Android and iPhone always run the chain', () {
      for (final platform in [
        lk.PlatformType.linux,
        lk.PlatformType.windows,
        lk.PlatformType.android,
        lk.PlatformType.iOS,
      ]) {
        expect(captureChainRunsOn(platform), isTrue, reason: '$platform');
      }
    });

    test('a browser runs it only when it can load the worklet', () {
      expect(captureChainRunsOn(lk.PlatformType.web), isFalse);
      expect(captureChainRunsOn(lk.PlatformType.web, webChain: true), isTrue);
    });

    test('macOS has no chain', () {
      expect(captureChainRunsOn(lk.PlatformType.macOS), isFalse);
    });
  });

  test('Strongest and the raw sample stay on the desktop plugin', () {
    for (final platform in lk.PlatformType.values) {
      expect(
        desktopChainRunsOn(platform),
        platform == lk.PlatformType.linux ||
            platform == lk.PlatformType.windows,
        reason: '$platform',
      );
    }
  });

  group('WebCaptureChainSettings', () {
    test('starts as an open gate with every stage off', () {
      expect(WebCaptureChainSettings().message, {
        'type': 'configure',
        'enabled': false,
        'thresholdDb': kDefaultInputThresholdDb,
        'dynamics': false,
        'levelAfterSuppression': false,
        'strongNoiseSuppression': false,
      });
    });

    test('carries what setInputGate sent, without Strongest', () {
      final settings = WebCaptureChainSettings()
        ..update({
          'enabled': true,
          'thresholdDb': -42,
          'dynamics': true,
          'levelAfterSuppression': true,
          'strongNoiseSuppression': true,
          'strongestNoiseSuppression': true,
        });
      expect(settings.message, {
        'type': 'configure',
        'enabled': true,
        'thresholdDb': -42.0,
        'dynamics': true,
        'levelAfterSuppression': true,
        'strongNoiseSuppression': true,
      });
    });

    test('a later call replaces every field, and junk keeps the last one', () {
      final settings = WebCaptureChainSettings()
        ..update({'enabled': true, 'strongNoiseSuppression': true})
        ..update({'dynamics': true})
        ..update('not a map');
      expect(settings.message['enabled'], isFalse);
      expect(settings.message['strongNoiseSuppression'], isFalse);
      expect(settings.message['dynamics'], isTrue);
    });
  });
}
