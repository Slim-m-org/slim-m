// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The leave control, drawn by whichever dock owns the call's far edge.
///
/// Decision 0047 point 2: leave is the last control in every dock, after a
/// divider, so it cannot be hit by a reach for something else. Its outline is
/// always danger and heavier than a muted mic's, which is a state.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import '../../../widgets/shortcut_label.dart';
import '../providers/voice_controller.dart';
import 'call_dock_button.dart';

class CallLeaveButton extends StatelessWidget {
  const CallLeaveButton({super.key, required this.controller});

  final VoiceController controller;

  @override
  Widget build(BuildContext context) => CallDockButton(
    icon: AppIcons.leaveCall,
    tooltip: labelWithShortcut('Leave call', AppAction.leaveCall),
    active: false,
    destructive: true,
    heavyOutline: true,
    onPressed: controller.leave,
  );
}
