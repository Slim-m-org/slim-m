// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer's action bar: attach, the field itself, and (space
/// permitting) poll, code, emoji and send.
///
/// Split out of `composer.dart`, already near its line budget. Presentational
/// only, like `ComposerField` and `ComposerBanners` beside it: every handler
/// is a plain callback the composer's own state already owns.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show Attachment;
import 'package:slimm_design_system/design_system.dart';

import '../providers/threads.dart';
import 'composer_extras.dart';
import 'composer_picker_button.dart';
import 'composer_gif_command.dart';
import 'composer_picker_panel.dart' show showComposerPickerSheet;
import 'composer_scrollbar.dart';
import 'composer_shortcodes.dart';
import 'poll_composer_sheet.dart';

class ComposerActionBar extends ConsumerWidget {
  const ComposerActionBar({
    super.key,
    required this.touch,
    required this.controller,
    required this.focusNode,
    required this.channelId,
    required this.channelName,
    required this.hasText,
    required this.canSend,
    required this.onSend,
    required this.onTyping,
    required this.onOpenActions,
    required this.onPickFile,
    required this.onSendPressed,
    required this.onInsertCode,
    required this.onPickEmoji,
    required this.gifSearchEnabled,
    required this.onInsertEmoji,
    required this.onStageGif,
    this.pickerController,
  });

  final bool touch;
  final TextEditingController controller;
  final FocusNode focusNode;
  final String channelId;
  final String channelName;
  final bool hasText;

  /// Whether this deployment offers GIF search at all
  /// (`Version.gifSearchEnabled`); the desktop icon button is absent, not
  /// disabled, when it does not.
  final bool gifSearchEnabled;

  /// Desktop-only handlers for `ComposerPickerButton`'s anchored panel:
  /// insert an emoji token at the caret, or stage a picked GIF as an
  /// attachment. Touch density never reaches these - see [onPickEmoji].
  final ValueChanged<String> onInsertEmoji;
  final ValueChanged<Attachment> onStageGif;

  /// Lets `/gif` open the anchored picker on its GIF tab.
  final ComposerPickerController? pickerController;

  /// Whether [onSendPressed] is offered at all right now; see
  /// `composer.dart`'s own `_canSend` for everything that feeds it.
  final bool canSend;
  final Future<void> Function() onSend;
  final ValueChanged<String> onTyping;
  final VoidCallback onOpenActions;
  final VoidCallback onPickFile;
  final VoidCallback onSendPressed;
  final VoidCallback onInsertCode;

  /// Touch density's own smile button: the Space-emoji-only sheet, since
  /// the OS keyboard already has every native one under the field.
  final VoidCallback onPickEmoji;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    // True only for the docked thread pane's own copy (`home_shell_pane_slots.dart`), where the parent channel's identical controls are also on screen.
    final isThread = ref.watch(openThreadProvider) == channelId;
    // A line break grows the bar over a beat, earlier lines holding still.
    return ComposerShortcodes(
      controller: controller,
      child: MaybeAnimatedSize(
        duration: AppMotion.fast,
        curve: AppMotion.entrance,
        alignment: Alignment.topCenter,
        child: Container(
          key: const Key('composer-action-bar'),
          decoration: BoxDecoration(
            color: tokens.surfaceRaised,
            border: Border.all(color: tokens.borderSubtle),
            borderRadius: BorderRadius.circular(AppRadii.card),
          ),
          child: ComposerScrollbarFrame(
            builder: (context, scrollController) => Padding(
              padding: const EdgeInsets.fromLTRB(12, 5, 10, 5),
              child: Row(
                // Top, not centred: a centred icon drifts as the field grows.
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppIconButton(
                    icon: AppIcons.add,
                    semanticLabel: touch ? 'More actions' : 'Attach a file',
                    tooltip: touch ? 'More actions' : 'Attach a file',
                    onPressed: touch ? onOpenActions : onPickFile,
                  ),
                  const SizedBox(width: AppSpacing.s8),
                  Expanded(
                    child: ComposerField(
                      controller: controller,
                      focusNode: focusNode,
                      channelName: channelName,
                      hasText: hasText,
                      onSend: onSend,
                      onTyping: onTyping,
                      isThread: isThread,
                      scrollController: scrollController,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s8),
                  // Behind the add button at touch density; see `showComposerActionsSheet`.
                  if (!touch) ...[
                    AppIconButton(
                      icon: AppIcons.poll,
                      semanticLabel: 'Create a poll',
                      tooltip: 'Create a poll',
                      onPressed: () =>
                          showPollComposerSheet(context, channelId),
                    ),
                    AppIconButton(
                      icon: AppIcons.code,
                      semanticLabel: 'Insert code',
                      tooltip: 'Insert code',
                      onPressed: onInsertCode,
                    ),
                    ComposerPickerButton(
                      controller: pickerController,
                      gifSearchEnabled: gifSearchEnabled,
                      onSelectEmoji: onInsertEmoji,
                      onPickedGif: onStageGif,
                    ),
                  ] else
                    AppIconButton(
                      icon: AppIcons.smile,
                      // Says what it opens: the GIFs tab is absent without a provider.
                      semanticLabel: gifSearchEnabled
                          ? 'Insert emoji or a GIF'
                          : 'Insert emoji',
                      tooltip: gifSearchEnabled
                          ? 'Insert emoji or a GIF'
                          : 'Insert emoji',
                      // Same two tabs the pointer panel has; see its own sheet doc.
                      onPressed: () => unawaited(
                        showComposerPickerSheet(
                          context,
                          onSelectEmoji: onInsertEmoji,
                          onPickedGif: onStageGif,
                          showGifTab: gifSearchEnabled,
                        ),
                      ),
                    ),
                  // Always rendered, only disabled when empty or over the limit.
                  AppIconButton(
                    icon: AppIcons.send,
                    semanticLabel: isThread ? 'Send reply' : 'Send message',
                    tooltip: isThread ? 'Send reply' : 'Send message',
                    onPressed: canSend ? onSendPressed : null,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
