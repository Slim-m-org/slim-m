// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The ways into Create emoji: the pane's one create button, in its title bar
/// on both layouts, and a drop on the pane.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../../action_labels.dart';
import 'emoji_add_dialog.dart';
import 'emoji_intake.dart';

/// True while the add dialog is open, so the pane behind it takes no drop of its own.
final emojiAddOpenProvider = StateProvider<bool>((ref) => false);

/// Opens the add dialog with [initial] already staged, as a drop on the pane does.
///
/// Desktop-vs-mobile rule 4, a short task with a submit: a centred dialog on a
/// desktop and a bottom sheet on a phone, over the pane it was opened from.
/// Staged files ask before they are dropped, so a phone cannot drag it away.
Future<void> showEmojiAddDialog(
  BuildContext context, {
  List<EmojiPick> initial = const [],
}) async {
  final open = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(emojiAddOpenProvider.notifier);
  if (open.state) return;
  open.state = true;
  try {
    await showAppSheet<void>(
      context,
      semanticLabel: ActionLabels.createEmoji,
      enableDrag: false,
      builder: (_) => EmojiAddDialog(initial: initial),
    );
  } finally {
    open.state = false;
  }
}

class EmojiCreateButton extends StatelessWidget {
  const EmojiCreateButton({super.key});

  @override
  Widget build(BuildContext context) => AppButton(
    label: ActionLabels.createEmoji,
    icon: AppIcons.add,
    onPressed: () => unawaited(showEmojiAddDialog(context)),
  );
}
