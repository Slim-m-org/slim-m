// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call controls laid over a full screen video: the share's volume, mute
/// and deafen.
///
/// There is deliberately no Leave here. It sits one tap from a stage the
/// viewer is only watching, and a misclick would drop the whole call.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/voice_controller.dart';
import '../providers/voice_flags.dart';
import 'stream_control_pill.dart';
import 'stream_volume_pill.dart';

class FullscreenVideoControls extends ConsumerWidget {
  const FullscreenVideoControls({
    super.key,
    required this.identity,
    required this.showVolume,
    required this.onHold,
  });

  final String identity;

  /// Whether this feed is a remote share carrying sound; a camera has none and a local share has nothing to attenuate.
  final bool showVolume;

  /// Keeps the surrounding reveal up while the volume is dragged.
  final ValueChanged<bool> onHold;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(voiceControllerProvider.notifier);
    final micOn = ref.watch(
      voiceFlagsProvider.select((f) => f.microphoneEnabled),
    );
    final deafened = ref.watch(voiceFlagsProvider.select((f) => f.deafened));
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      spacing: AppSpacing.s8,
      children: [
        if (showVolume)
          Flexible(
            child: StreamVolumePill(
              identity: identity,
              controller: controller,
              onHold: onHold,
            ),
          ),
        StreamControlPill(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIconButton(
                icon: micOn ? AppIcons.mic : AppIcons.micOff,
                semanticLabel: micOn ? 'Mute' : 'Unmute',
                tooltip: micOn ? 'Mute' : 'Unmute',
                variant: micOn
                    ? AppIconButtonVariant.ghost
                    : AppIconButtonVariant.danger,
                onPressed: controller.toggleMicrophone,
              ),
              AppIconButton(
                icon: deafened ? AppIcons.headphonesOff : AppIcons.headphones,
                semanticLabel: deafened ? 'Undeafen' : 'Deafen',
                tooltip: deafened ? 'Undeafen' : 'Deafen',
                variant: deafened
                    ? AppIconButtonVariant.danger
                    : AppIconButtonVariant.ghost,
                onPressed: controller.toggleDeafen,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
