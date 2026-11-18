// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer's action bar: attach, the field itself, and (space
/// permitting) poll, code, emoji and send. Space is the bar's own width, not
/// the window's: beside a docked member or thread pane a wide window still
/// leaves a narrow bar.
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

import '../../../widgets/anchored_menu.dart';
import '../../../widgets/animated_menu_portal.dart';
import '../../channels/providers/threads.dart';
import '../providers/voice_recording.dart';
import 'composer_extras.dart';
import 'composer_picker_button.dart';
import 'composer_gif_command.dart';
import 'composer_picker_panel.dart' show showComposerPickerSheet;
import 'composer_scrollbar.dart';
import 'composer_shortcodes.dart';
import 'composer_voice_bar.dart';
import 'poll_composer_sheet.dart';

/// Below this bar width a pointer composer folds poll, code and apps behind
/// its add button. With all of them on the row the field would be narrower
/// than everything beside it, about 200, the field a phone composer keeps.
const double kComposerFoldWidth = 390;

typedef _ComposerAction = (IconData icon, String label, VoidCallback onPressed);

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
    required this.canRecord,
    required this.onVoiceSent,
    required this.onSend,
    required this.onTyping,
    required this.onOpenActions,
    this.onLaunchApps,
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

  /// Whether the mic may stand in for Send: an empty composer with nothing staged.
  final bool canRecord;

  /// Takes a recorded voice message once it is uploaded.
  final VoiceSent onVoiceSent;
  final Future<void> Function() onSend;
  final ValueChanged<String> onTyping;
  final VoidCallback onOpenActions;

  /// Null when the deployment has no apps to launch, so no dead button shows.
  final VoidCallback? onLaunchApps;
  final VoidCallback onPickFile;
  final VoidCallback onSendPressed;
  final VoidCallback onInsertCode;

  /// Touch density's own smile button: the Space-emoji-only sheet, since
  /// the OS keyboard already has every native one under the field.
  final VoidCallback onPickEmoji;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // True only for the docked thread pane's own copy (`home_shell_pane_slots.dart`), where the parent channel's identical controls are also on screen.
    final isThread = ref.watch(dockedThreadsProvider).containsValue(channelId);
    final recording = ref.watch(
      voiceRecorderProvider(channelId).select((s) => s.isActive),
    );
    // A line break grows the bar over a beat, earlier lines holding still.
    return ComposerShortcodes(
      controller: controller,
      child: LayoutBuilder(
        builder: (context, box) => _bar(
          context,
          ref,
          isThread: isThread,
          recording: recording,
          folded: touch || box.maxWidth < kComposerFoldWidth,
        ),
      ),
    );
  }

  Widget _bar(
    BuildContext context,
    WidgetRef ref, {
    required bool isThread,
    required bool recording,
    required bool folded,
  }) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return MaybeAnimatedSize(
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
            child: recording
                ? ComposerVoiceBar(channelId: channelId, onSent: onVoiceSent)
                : Row(
                    // Top, not centred: a centred icon drifts as the field grows.
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _leadingButton(context, folded: folded),
                      const SizedBox(width: AppSpacing.s8),
                      // Keyed: a fold changes the leading button's type, which would remount the field and drop its keyboard.
                      Expanded(
                        key: const ValueKey('composer-field'),
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
                      if (touch)
                        _touchEmojiButton(context)
                      else ...[
                        if (!folded) ..._extraButtons(context),
                        _pickerButton(),
                      ],
                      if (canRecord && !canSend)
                        ComposerMicButton(
                          onPressed: () => unawaited(
                            ref
                                .read(voiceRecorderProvider(channelId).notifier)
                                .start(),
                          ),
                        )
                      else
                        // Disabled when empty or over the limit.
                        AppIconButton(
                          icon: AppIcons.send,
                          semanticLabel: isThread
                              ? 'Send reply'
                              : 'Send message',
                          tooltip: isThread ? 'Send reply' : 'Send message',
                          onPressed: canSend ? onSendPressed : null,
                        ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _leadingButton(BuildContext context, {required bool folded}) {
    if (touch) return _addButton('More actions', onOpenActions);
    if (!folded) return _addButton('Attach a file', onPickFile);
    return _FoldedActionsButton(
      actions: [
        (AppIcons.attachFile, 'Attach a file', onPickFile),
        ..._extras(context),
      ],
    );
  }

  Widget _addButton(String label, VoidCallback onPressed) => AppIconButton(
    icon: AppIcons.add,
    semanticLabel: label,
    tooltip: label,
    onPressed: onPressed,
  );

  /// Poll, code and apps: on the row when it has room, behind add when not.
  List<_ComposerAction> _extras(BuildContext context) => [
    (
      AppIcons.poll,
      'Create a poll',
      () => showPollComposerSheet(context, channelId),
    ),
    (AppIcons.code, 'Insert code', onInsertCode),
    if (onLaunchApps case final launch?)
      (AppIcons.dock, 'Launch an app', launch),
  ];

  List<Widget> _extraButtons(BuildContext context) => [
    for (final (icon, label, onPressed) in _extras(context))
      AppIconButton(
        icon: icon,
        semanticLabel: label,
        tooltip: label,
        onPressed: onPressed,
      ),
  ];

  Widget _pickerButton() => ComposerPickerButton(
    controller: pickerController,
    gifSearchEnabled: gifSearchEnabled,
    onSelectEmoji: onInsertEmoji,
    onPickedGif: onStageGif,
    channelId: channelId,
  );

  Widget _touchEmojiButton(BuildContext context) {
    // Says what it opens: the GIFs tab is absent without a provider.
    final label = gifSearchEnabled ? 'Insert emoji or a GIF' : 'Insert emoji';
    return AppIconButton(
      icon: AppIcons.smile,
      semanticLabel: label,
      tooltip: label,
      // Same two tabs the pointer panel has; see its own sheet doc.
      onPressed: () => unawaited(
        showComposerPickerSheet(
          context,
          onSelectEmoji: onInsertEmoji,
          onPickedGif: onStageGif,
          channelId: channelId,
          showGifTab: gifSearchEnabled,
        ),
      ),
    );
  }
}

/// Add on a bar too narrow for its extras: one menu, opening upward off the
/// button, with each action it hides (desktop-vs-mobile rule 1).
class _FoldedActionsButton extends StatefulWidget {
  const _FoldedActionsButton({required this.actions});

  final List<_ComposerAction> actions;

  @override
  State<_FoldedActionsButton> createState() => _FoldedActionsButtonState();
}

class _FoldedActionsButtonState extends State<_FoldedActionsButton> {
  final _menu = AnimatedMenuController();

  @override
  Widget build(BuildContext context) {
    return AnchoredMenu(
      controller: _menu,
      targetAnchor: Alignment.topLeft,
      followerAnchor: Alignment.bottomLeft,
      offset: const Offset(0, -AppSpacing.s4),
      menu: AppMenu(
        children: [
          for (final (icon, label, onPressed) in widget.actions)
            AppMenuItem(
              label: label,
              leading: icon,
              onTap: () {
                _menu.hide();
                onPressed();
              },
            ),
        ],
      ),
      child: AppIconButton(
        icon: AppIcons.add,
        semanticLabel: 'More actions',
        tooltip: 'More actions',
        onPressed: _menu.toggle,
      ),
    );
  }
}
