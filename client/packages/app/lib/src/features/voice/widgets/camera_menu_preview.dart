// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The small live view of your own camera under the camera menu's device row.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/voice_controller.dart';
import '../providers/voice_flags.dart';

/// Fixed height; the width is the menu's content width.
const cameraMenuPreviewHeight = 96.0;

class CameraMenuPreview extends ConsumerWidget {
  const CameraMenuPreview({super.key, required this.controller});

  final VoiceController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final self = ref
        .watch(voiceParticipantsProvider)
        .where((p) => p.isLocal)
        .firstOrNull;
    return SizedBox(
      height: cameraMenuPreviewHeight,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.control),
        child: ColoredBox(
          color: tokens.surfaceSunken,
          child: self == null
              ? null
              : controller.cameraViewFor(
                  self.identity,
                  declaresInterest: false,
                ),
        ),
      ),
    );
  }
}
