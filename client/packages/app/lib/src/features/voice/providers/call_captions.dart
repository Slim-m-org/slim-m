// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one Captions control and what it reveals (decision 0113): whether the
/// call offers it, and the viewer's choices for this call. The transcript runs
/// in the background; captions and the Chat | Transcript pane show only on request.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../permissions.dart';
import '../../channels/providers/channel_permissions.dart';
import 'call_audio.dart';
import 'live_call_transcript.dart';
import 'voice_settings_controller.dart';

/// What the Captions control is doing in a call.
enum CaptionsControl {
  /// Not offered: transcription is off here, a module hears the call, or the member may not read transcripts.
  hidden,

  /// A transcript runs; the control reveals it.
  running,

  /// Everyone is being asked; the control says it is waiting.
  pending,

  /// Nothing runs and the Space allows asking; turning captions on asks everyone.
  startable,
}

final captionsControlProvider = Provider.autoDispose
    .family<CaptionsControl, String>((ref, channelId) {
      final bits = ref.watch(myChannelPermissionsProvider(channelId));
      if (!bits.hasPermission(Perm.viewChannel | Perm.viewTranscripts)) {
        return CaptionsControl.hidden;
      }
      if (ref.watch(liveCallTranscriptIdProvider(channelId)) != null) {
        return CaptionsControl.running;
      }
      final model = ref.watch(callAudioProvider(channelId));
      final session = model.session;
      if (session != null) {
        return session.isServerTranscript && !session.isOn
            ? CaptionsControl.pending
            : CaptionsControl.hidden;
      }
      return model.status.transcribable
          ? CaptionsControl.startable
          : CaptionsControl.hidden;
    });

/// The viewer's choices in this call, dropped when the transcript or its ask ends.
class CallCaptionsChoice {
  const CallCaptionsChoice({this.captions, this.transcriptShown = false});

  /// Null follows the per-device default.
  final bool? captions;

  /// "View transcript" was chosen, so the pane switch is offered.
  final bool transcriptShown;
}

class CallCaptionsController
    extends AutoDisposeFamilyNotifier<CallCaptionsChoice, String> {
  @override
  CallCaptionsChoice build(String arg) {
    ref.listen(callAudioProvider(arg).select((m) => m.session != null), (
      was,
      has,
    ) {
      if (was == true && !has) state = const CallCaptionsChoice();
    });
    return const CallCaptionsChoice();
  }

  void setCaptions(bool on) => state = CallCaptionsChoice(
    captions: on,
    transcriptShown: state.transcriptShown,
  );

  void reset() => state = const CallCaptionsChoice();

  void showTranscript() => state = CallCaptionsChoice(
    captions: state.captions,
    transcriptShown: true,
  );
}

final callCaptionsProvider = NotifierProvider.autoDispose
    .family<CallCaptionsController, CallCaptionsChoice, String>(
      CallCaptionsController.new,
    );

/// Whether the Captions switch reads on: this call's choice, else the device default once a transcript runs.
final captionsOnProvider = Provider.autoDispose.family<bool, String>((
  ref,
  channelId,
) {
  final choice = ref.watch(callCaptionsProvider(channelId));
  if (ref.watch(captionsControlProvider(channelId)) !=
      CaptionsControl.running) {
    return choice.captions ?? false;
  }
  return choice.captions ??
      ref.watch(voiceSettingsControllerProvider.select((s) => s.showCaptions));
});

/// Whether the caption strip shows: a transcript runs and captions are on.
final captionsShownProvider = Provider.autoDispose.family<bool, String>(
  (ref, channelId) =>
      ref.watch(captionsControlProvider(channelId)) ==
          CaptionsControl.running &&
      ref.watch(captionsOnProvider(channelId)),
);

/// Whether the Chat | Transcript pane switch is offered: captions on, or "View transcript" chosen.
final transcriptPaneOfferedProvider = Provider.autoDispose.family<bool, String>(
  (ref, channelId) =>
      ref.watch(captionsControlProvider(channelId)) ==
          CaptionsControl.running &&
      (ref.watch(captionsOnProvider(channelId)) ||
          ref.watch(callCaptionsProvider(channelId)).transcriptShown),
);
