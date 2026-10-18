// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The device pickers in setup: a list that arrives late (a host that only
/// lists devices once the microphone is open) shows up, and the empty list
/// before the first answer is not read as an unplugged device.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/first_run/widgets/first_run_device_steps.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_select_row.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/fake_mic_preview.dart';
import 'voice_settings_screen_harness.dart';

const _usb = AudioDevice(id: 'usb', label: 'USB headset');

class _LateSession extends FakeSession {
  List<AudioDevice> mics = const [];
  Completer<void>? hold;

  @override
  Future<List<AudioDevice>> audioInputDevices() async {
    await hold?.future;
    return mics;
  }
}

/// A host that lists its devices only once a capture is open.
class _ListsOnOpen extends FakeMicSource {
  _ListsOnOpen(this._session);

  final _LateSession _session;

  @override
  Future<void> open(String? deviceId) async {
    await super.open(deviceId);
    _session.mics = const [_usb];
  }
}

Future<void> _mount(
  WidgetTester tester,
  _LateSession session,
  FakeMicSource source,
) => tester.pumpWidget(
  wrap(
    const FirstRunVoiceStep(),
    overrides: [
      voiceControllerProvider.overrideWith(
        (ref) => VoiceController(ref, session: session),
      ),
      fakeMicPreview(source),
    ],
  ),
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _leave(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
}

Finder _micRow() => find.byWidgetPredicate(
  (w) => w is SettingsSelectRow<String> && w.label == 'Microphone',
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('microphones that only list once the mic is open appear', (
    tester,
  ) async {
    final session = _LateSession();
    await _mount(tester, session, _ListsOnOpen(session));
    await _settle(tester);
    await _settle(tester);
    await tester.tap(_micRow());
    await tester.pumpAndSettle();

    expect(find.text('USB headset'), findsOneWidget);
    await _leave(tester);
  });

  testWidgets('a saved microphone is not called unplugged before the first '
      'list arrives', (tester) async {
    SharedPreferences.setMockInitialValues({
      'slimm.voice.audio_input_device_id': 'usb',
    });
    final session = _LateSession()..hold = Completer<void>();
    await _mount(tester, session, FakeMicSource());
    await _settle(tester);

    expect(find.textContaining("isn't connected"), findsNothing);

    session.mics = const [_usb];
    session.hold!.complete();
    await _settle(tester);

    expect(find.textContaining("isn't connected"), findsNothing);
    await _leave(tester);
  });

  testWidgets('a saved microphone missing from a real list is called out', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'slimm.voice.audio_input_device_id': 'gone',
    });
    final session = _LateSession()..mics = const [_usb];
    await _mount(tester, session, FakeMicSource());
    await _settle(tester);

    expect(find.textContaining("isn't connected"), findsOneWidget);
    await _leave(tester);
  });
}
