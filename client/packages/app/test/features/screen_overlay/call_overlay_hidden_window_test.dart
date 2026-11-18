// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call panel keeps up while the main window is hidden to the tray, when
/// Flutter draws no frames and a derived provider never refreshes.
library;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_rtc/rtc.dart';

import 'overlay_rig.dart';

VoiceParticipant _person(
  String name, {
  bool local = false,
  bool muted = false,
}) => VoiceParticipant(
  identity: name,
  name: name,
  isSpeaking: false,
  isMuted: muted,
  isLocal: local,
  isScreenSharing: false,
);

VoiceState _call(List<VoiceParticipant> people) => VoiceState(
  channelId: 'call',
  state: VoiceSessionState.connected,
  participants: people,
);

void main() {
  testWidgets('a mute and a join reach the panel with no frame drawn', (
    tester,
  ) async {
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    final rig = OverlayRig(
      allow: false,
      callOverlay: true,
      initial: _call([_person('me', local: true), _person('web')]),
    );
    addTearDown(rig.container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: rig.container,
        child: const SizedBox(),
      ),
    );
    await tester.pump();
    expect(rig.overlay.panels.last!.rows.map((r) => r.name), [
      'me (you)',
      'web',
    ]);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    expect(SchedulerBinding.instance.framesEnabled, isFalse);
    rig.voice.set(
      _call([
        _person('me', local: true),
        _person('web', muted: true),
        _person('new'),
      ]),
    );
    await tester.idle();

    final rows = rig.overlay.panels.last!.rows;
    expect(rows.map((r) => r.name), ['me (you)', 'web', 'new']);
    expect(rows[1].muted, isTrue);
  });
}
