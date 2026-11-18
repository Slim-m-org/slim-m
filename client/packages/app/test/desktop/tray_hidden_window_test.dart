// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The tray menu keeps up with the call while the window is hidden to the
/// tray, when Flutter draws no frames and a derived provider never refreshes.
library;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/tray/desktop_tray_controller.dart';
import 'package:slimm_rtc/rtc.dart';

import '../features/voice/voice_controller_harness.dart';
import 'support/fake_desktop_window_port.dart';

const _channel = MethodChannel('tray_manager');

Future<void> _click(int id) async {
  final call = MethodCall('onTrayMenuItemClick', {'id': id});
  final data = const StandardMethodCodec().encodeMethodCall(call);
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(_channel.name, data, (_) {});
}

void main() {
  testWidgets('a mute from the tray or a hotkey relabels the menu with no '
      'frame drawn', (tester) async {
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    final menus = <List<Map<Object?, Object?>>>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (
      call,
    ) async {
      if (call.method == 'setContextMenu') {
        final menu = (call.arguments as Map)['menu'] as Map;
        menus.add((menu['items'] as List).cast());
      }
      return true;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _channel,
        null,
      ),
    );
    final harness = VoiceHarness();
    addTearDown(harness.dispose);
    final session = FakeSession();
    final voice = harness.controllerWith(session, voiceApi());
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: harness.container,
        child: const SizedBox(),
      ),
    );
    final tray = DesktopTrayController(
      port: FakeDesktopWindowPort(),
      container: harness.container,
    );
    await tray.start();
    addTearDown(tray.dispose);
    await voice.join('channel-1');
    session.emitState(VoiceSessionState.connected);
    await tester.pump();

    List<Object?> labels() => [for (final i in menus.last) i['label']];
    int idOf(String label) =>
        menus.last.firstWhere((i) => i['label'] == label)['id']! as int;
    expect(labels(), contains('Mute microphone'));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    expect(SchedulerBinding.instance.framesEnabled, isFalse);

    await _click(idOf('Mute microphone'));
    await tester.idle();
    expect(labels(), contains('Unmute microphone'));

    await voice.toggleMicrophone();
    await voice.toggleDeafen();
    await tester.idle();
    expect(labels(), containsAll(['Mute microphone', 'Undeafen']));

    await voice.leave();
    await tester.idle();
    expect(labels(), isNot(contains('Leave call')));
    expect(SchedulerBinding.instance.framesEnabled, isFalse);
  });
}
