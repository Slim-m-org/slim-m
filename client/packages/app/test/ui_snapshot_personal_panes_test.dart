// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every personal settings pane, opened by tapping its nav row the way a
/// person does, at the phone and desktop widths in both themes.
///
/// The voice controller is pinned to an idle fake: the real one reaches livekit's
/// device enumeration, which throws on the missing webrtc plugin in whichever
/// test happens to mount the voice pane first in a process.
///
/// `/settings` alone only ever renders the first pane, which is how the other
/// eight went unlooked-at by the snapshot matrix.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';

import 'ui_snapshot_support.dart';
import 'features/voice/voice_snapshot_fixtures.dart'
    show SnapshotVoiceController;
import 'package:slimm_app/src/action_labels.dart';

const _panes = <String, String>{
  'profile': 'Profile',
  'account-devices': 'Account & devices',
  'appearance': 'Appearance',
  'performance': ActionLabels.mediaAndCache,
  'notifications': 'Notifications',
  'voice': 'Voice & screen share',
  'blocked': 'Blocked',
  'report-status': 'Report status',
  'about': 'About slim-m',
};

/// Panes whose own real-time work (a version lookup, the mic probe) lands
/// between two captures, so a second theme in the same mount would show a later state.
const _realTimePanes = {'about', 'voice'};

final _idleVoice = voiceControllerProvider.overrideWith(
  (ref) => SnapshotVoiceController(ref, const VoiceState()),
);

void main() {
  setUpAll(loadRealFonts);

  testWidgets('settings menu at phone-portrait ($darkAndLight)', (
    tester,
  ) async {
    await renderSurface(
      tester,
      '/settings',
      'phone-portrait',
      darkAndLight,
      'settings-menu-phone-portrait-$darkAndLight',
      overrides: [_idleVoice],
    );
  });
  for (final pane in _panes.entries) {
    final themes = _realTimePanes.contains(pane.key)
        ? const ['dark', 'light']
        : const [darkAndLight];
    for (final theme in themes) {
      for (final viewport in phoneAndDesktop) {
        testWidgets('settings pane ${pane.key} at $viewport ($theme)', (
          tester,
        ) async {
          await renderSurface(
            tester,
            '/settings',
            viewport,
            theme,
            'settings-pane-${pane.key}-$viewport-$theme',
            overrides: [_idleVoice],
            afterSettle: (tester) async {
              await tester.tap(find.text(pane.value).first);
              await tester.pump();
            },
          );
        });
      }
    }
  }
}
