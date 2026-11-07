// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call dock laid over a full screen video: the same controls the call
/// screen docks, folded behind a handle so nothing covers the picture until a
/// pointer nears the bottom edge or the handle is pressed.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/dock_collapse.dart';
import '../../../widgets/floating_dock_card.dart';
import '../providers/voice_controller.dart';
import '../providers/voice_flags.dart';
import 'call_leave_button.dart';
import 'voice_call_controls.dart';

class FullscreenVideoDock extends ConsumerWidget {
  const FullscreenVideoDock({super.key});

  static const Key dockKey = Key('fullscreen_video_dock');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(voiceControllerProvider.notifier);
    final voice = ref.watch(voiceFlagsProvider);
    return DockCollapse(
      collapsible: true,
      builder: (context, revealed) => Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.s12,
          0,
          AppSpacing.s12,
          AppSpacing.s12,
        ),
        child: FloatingDockCard(
          key: dockKey,
          trailing: CallLeaveButton(controller: controller),
          hugsWidth: true,
          rows: [
            CallControls(
              controller: controller,
              voice: voice,
              ownsShortcuts: false,
            ),
          ],
        ),
      ),
    );
  }
}
