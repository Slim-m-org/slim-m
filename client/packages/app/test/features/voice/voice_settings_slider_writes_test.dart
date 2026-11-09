// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A dragged slider applies every frame but is written to disk once it rests:
/// a synchronous whole-file write per frame is what dragging used to cost.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/settled_double_writes.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';

import 'voice_settings_screen_harness.dart';

class _CountingPrefs extends Fake implements SharedPreferences {
  final writes = <(String, double)>[];

  @override
  Future<bool> setDouble(String key, double value) async {
    writes.add((key, value));
    return true;
  }

  @override
  String? getString(String key) => null;

  @override
  int? getInt(String key) => null;

  @override
  bool? getBool(String key) => null;

  @override
  double? getDouble(String key) => null;
}

class _Rig {
  _Rig() {
    container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWith((ref) async => prefs),
        voiceControllerProvider.overrideWith(
          (ref) => VoiceController(ref, session: session),
        ),
      ],
    );
    controller = container.read(voiceSettingsControllerProvider.notifier);
  }

  final prefs = _CountingPrefs();
  final session = FakeSession();
  late final ProviderContainer container;
  late final VoiceSettingsController controller;

  VoiceSettingsState get settings =>
      container.read(voiceSettingsControllerProvider);
}

void _drag(FakeAsync async, void Function(double fraction) move) {
  for (var i = 1; i <= 30; i++) {
    move(i / 30);
    async.elapse(const Duration(milliseconds: 16));
  }
}

void main() {
  test('dragging the hold music volume writes it once, when it rests', () {
    fakeAsync((async) {
      final rig = _Rig();
      async.flushMicrotasks();

      _drag(
        async,
        (f) => unawaited(rig.controller.setHoldMusicVolume(f * 0.6)),
      );

      expect(rig.settings.holdMusicVolume, closeTo(0.6, 1e-9));
      expect(rig.prefs.writes, isEmpty);
      async.elapse(kSettledWriteDelay);
      expect(rig.prefs.writes, [(VoiceSettingKeys.holdMusicVolume, 0.6)]);
    });
  });

  test('dragging the sensitivity reaches the call at once and disk once', () {
    fakeAsync((async) {
      final rig = _Rig();
      async.flushMicrotasks();

      _drag(
        async,
        (f) => unawaited(rig.controller.setVoiceActivitySensitivity(f * 80)),
      );

      expect(rig.session.lastSpeakingSensitivity, closeTo(0.8, 1e-9));
      expect(rig.prefs.writes, isEmpty);
      async.elapse(kSettledWriteDelay);
      expect(rig.prefs.writes, [(VoiceSettingKeys.sensitivity, 80.0)]);
    });
  });

  test('dragging the input threshold reaches the gate before it is saved', () {
    fakeAsync((async) {
      final rig = _Rig();
      async.flushMicrotasks();

      _drag(
        async,
        (f) => unawaited(rig.controller.setInputThreshold(-60 + f * 20)),
      );

      expect(rig.session.inputGateCalls.last.thresholdDb, closeTo(-40, 1e-9));
      expect(rig.prefs.writes, isEmpty);
      async.elapse(kSettledWriteDelay);
      expect(rig.prefs.writes, [(VoiceSettingKeys.inputThreshold, -40.0)]);
    });
  });

  test('a value still waiting is written when the settings go away', () {
    fakeAsync((async) {
      final rig = _Rig();
      async.flushMicrotasks();
      unawaited(rig.controller.setHoldMusicVolume(0.3));
      async.flushMicrotasks();

      rig.container.dispose();

      expect(rig.prefs.writes, [(VoiceSettingKeys.holdMusicVolume, 0.3)]);
    });
  });
}
