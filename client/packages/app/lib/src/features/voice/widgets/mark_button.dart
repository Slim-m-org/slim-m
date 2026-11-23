// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call control that marks this moment of a transcribed call; a long
/// press or right-click offers "Add a note" instead.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import '../../../widgets/control_options_menu.dart';
import '../../../widgets/shortcut_label.dart';
import '../providers/call_mark_actions.dart';
import 'call_dock_button.dart';
import 'call_note_sheet.dart';

const markButtonKey = Key('call-mark-button');

class MarkButton extends ConsumerWidget {
  const MarkButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ControlOptionsMenu(
      showCaret: false,
      optionsLabel: 'Mark options',
      options: [
        ControlOption(
          label: 'Add a note',
          icon: AppIcons.callNote,
          onSelected: () => unawaited(showCallNoteSheet(context)),
        ),
      ],
      child: CallDockButton(
        key: markButtonKey,
        icon: AppIcons.callMark,
        tooltip: labelWithShortcut(
          'Mark this moment',
          AppAction.markCallMoment,
        ),
        active: false,
        holdOpensOptions: true,
        onPressed: () => unawaited(ref.read(callMarkActionsProvider).mark()),
      ),
    );
  }
}
