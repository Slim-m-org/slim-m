// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one affordance that opens a channel's canvas.
///
/// It sits in a voice channel's header, at every width, rather than only
/// inside a live call: a call needs a configured SFU and somebody already in
/// it, so an in-call-only entry would leave the product's signature feature
/// invisible whenever the room is empty.
///
/// Voice channels and DMs, not text channels, by owner decision. The
/// original call (backlog, 2026-08-13, "there also should not be a canvas
/// in text channels, only voice channels") also read as excluding DMs, since
/// a DM's base permissions granted no `USE_CANVAS` at the time. The owner
/// has since asked for a DM canvas too, to work through something 1-on-1
/// without needing a voice channel for it, which supersedes that reading:
/// `DM_BASE` (`store/dms.rs`) now grants `USE_CANVAS`, and this button opens
/// for a DM the same way it does for a voice channel - the personal space
/// (self-DM) included, where it doubles as a personal scratch canvas rather
/// than needing its own special case. Text channels stay excluded on the
/// original rule: the canvas belongs to talking together or to a direct
/// conversation, not to a channel of many.
///
/// The kind arrives as [isVoice] and [isDm] from the header that builds
/// this, rather than being read back out of the local store: every call
/// site already knows both, and a store round trip would make an affordance
/// appear a frame or two late on a screen that has the answer synchronously.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../voice/providers/voice_flags.dart';
import '../screens/canvas_pane.dart';

class CanvasOpenButton extends ConsumerWidget {
  const CanvasOpenButton({
    super.key,
    required this.channelId,
    required this.isVoice,
    this.isDm = false,
  });

  final String channelId;

  /// Whether this channel is a voice channel or a DM - the two kinds a
  /// canvas can open in. Everything else (a text channel) hides this.
  final bool isVoice;

  /// Whether this channel is a DM, personal space included. Defaults false
  /// so every existing caller that predates the DM canvas keeps its old
  /// voice-only behavior until it opts in.
  final bool isDm;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!isVoice && !isDm) return const SizedBox.shrink();
    final open = ref.watch(canvasOpenProvider) == channelId;
    // The call dock carries the canvas toggle while this channel's call is live or auto-rejoining.
    final voice = ref.watch(voiceFlagsProvider);
    if (isVoice && voice.inCallStageFor(channelId)) {
      return const SizedBox.shrink();
    }
    return _button(ref, open);
  }

  Widget _button(WidgetRef ref, bool open) => AppIconButton(
    icon: AppIcons.canvas,
    semanticLabel: open ? 'Close canvas' : 'Open canvas',
    active: open,
    onPressed: () =>
        ref.read(canvasOpenProvider.notifier).state = open ? null : channelId,
  );
}
