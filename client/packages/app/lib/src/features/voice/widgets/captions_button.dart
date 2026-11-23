// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call control that turns captions on or off on this device.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/live_call_transcript.dart';
import '../providers/voice_settings_controller.dart';
import 'call_dock_button.dart';

/// Whether [channelId]'s call offers captions to this member: the server
/// transcribes it and they may read the transcript.
bool canUseCaptions(WidgetRef ref, String? channelId) =>
    channelId != null &&
    ref.watch(liveCallTranscriptIdProvider(channelId)) != null;

class CaptionsButton extends ConsumerWidget {
  const CaptionsButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(
      voiceSettingsControllerProvider.select((s) => s.showCaptions),
    );
    return CallDockButton(
      icon: AppIcons.callCaptions,
      tooltip: on ? 'Hide captions' : 'Show captions',
      active: on,
      onPressed: () => unawaited(
        ref.read(voiceSettingsControllerProvider.notifier).setShowCaptions(!on),
      ),
    );
  }
}
