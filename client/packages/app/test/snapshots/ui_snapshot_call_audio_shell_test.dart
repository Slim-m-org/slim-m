// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call-audio banner inside the real call stage with its neighbouring
/// banners, and the prompt over the whole shell, at desktop and phone width in
/// both themes. PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/call_audio.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/call_audio_prompt.dart';

import '../features/voice/voice_snapshot_fixtures.dart'
    show SnapshotVoiceController, callWithErrorState, connectedCallState;
import '../ui_snapshot_support.dart';

class _FixedCallAudio extends CallAudioController {
  _FixedCallAudio(this._session);

  final api.CallAudioState _session;

  @override
  CallAudioModel build(String arg) {
    channelId = arg;
    return CallAudioModel(status: api.CallAudioStatus(session: _session));
  }
}

api.CallAudioState _session({
  required bool on,
  List<String> pending = const [],
}) => api.CallAudioState(
  moduleId: 'transcript',
  moduleName: 'Transcript',
  purpose: 'Writes down what is said.',
  keeps: 'The text, for 30 days.',
  isOn: on,
  askedBy: 'user-ada',
  included: const ['user-ada'],
  pending: pending,
  expiresAtMs: 4102444800000,
  full: false,
);

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in phoneAndDesktop) {
    testWidgets('call audio banner in the call stage at $viewport', (
      tester,
    ) async {
      await renderSurfaceThemes(
        tester,
        '/channels/c-main',
        viewport,
        const ['dark', 'light'],
        (t) => 'call-audio-shell-banner-$viewport-$t',
        overrides: [
          voiceControllerProvider.overrideWith(
            (ref) => SnapshotVoiceController(ref, callWithErrorState),
          ),
          callAudioProvider.overrideWith(
            () => _FixedCallAudio(_session(on: true)),
          ),
        ],
      );
    });

    testWidgets('call audio prompt over the call shell at $viewport', (
      tester,
    ) async {
      await renderSurfaceThemes(
        tester,
        '/channels/c-main',
        viewport,
        const ['dark', 'light'],
        (t) => 'call-audio-shell-prompt-$viewport-$t',
        overrides: [
          voiceControllerProvider.overrideWith(
            (ref) => SnapshotVoiceController(ref, connectedCallState),
          ),
          callAudioProvider.overrideWith(
            () => _FixedCallAudio(
              _session(on: false, pending: const ['user-nick', 'user-bob']),
            ),
          ),
        ],
        // The prompt's own countdown ticks once a second across the settle pumps.
        knownTransient: true,
        overlays: const [Positioned.fill(child: CallAudioPrompt())],
      );
    });
  }
}
