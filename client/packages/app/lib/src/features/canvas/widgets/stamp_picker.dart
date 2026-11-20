// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one Stamp picker (decision 0121): the reaction picker's emoji, the
/// composer's GIF search, or a picture of your own, for a share or the board.
/// A popover beside the Stamp button on a wide window, a sheet on a narrow one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/server_info.dart';
import '../../../widgets/anchored_popover_or_sheet.dart';
import '../../composer/widgets/gif_picker.dart' show GifPickerBody;
import '../../emoji/providers/emoji_catalog_provider.dart';
import '../../composer/widgets/composer_emoji_browse.dart'
    show ComposerEmojiPicker;
import '../../emoji/widgets/emoji_picker_panel.dart' show pickerWidth;
import '../../emoji/widgets/stored_emoji.dart' show storableEmoji;
import '../../screen_overlay/providers/stamp_content.dart';
import '../../screen_overlay/providers/stamp_picture_upload.dart';
import '../providers/armed_stamp.dart';
import 'stamp_picture_tab.dart';

enum _StampTab { emoji, gifs, picture }

/// Opens the picker beside [anchor]; what is picked is armed and handed to [onPicked].
Future<void> showStampPicker(
  BuildContext anchor, {
  required ValueChanged<StampContent> onPicked,
  String? channelId,
  Rect? anchorRect,
}) => showAnchoredPopoverOrSheet<void>(
  anchor,
  anchorRect: anchorRect,
  semanticLabel: 'Choose a stamp',
  popoverBuilder: (context) => AppMenu(
    width: pickerWidth,
    children: [
      StampPicker(channelId: channelId, onPicked: onPicked, sheet: false),
    ],
  ),
  sheetBuilder: (context) => SafeArea(
    top: false,
    child: StampPicker(channelId: channelId, onPicked: onPicked, sheet: true),
  ),
);

class StampPicker extends ConsumerStatefulWidget {
  const StampPicker({
    super.key,
    required this.onPicked,
    this.channelId,
    this.sheet = false,
  });

  final ValueChanged<StampContent> onPicked;

  /// The channel a GIF or picture is headed for, so its overwrites count.
  final String? channelId;

  /// In a bottom sheet, where the search field waits for a tap rather than raising the keyboard.
  final bool sheet;

  @override
  ConsumerState<StampPicker> createState() => _StampPickerState();
}

class _StampPickerState extends ConsumerState<StampPicker> {
  _StampTab _tab = _StampTab.emoji;
  final _body = GlobalKey();

  /// The first tab's height, which every tab of a popover keeps so the popover never moves.
  double? _bodyHeight;

  void _select(_StampTab tab) {
    if (!widget.sheet) _bodyHeight ??= _body.currentContext?.size?.height;
    setState(() => _tab = tab);
  }

  void _pick(StampContent content) {
    ref.read(armedStampProvider.notifier).arm(content);
    Navigator.of(context).maybePop();
    widget.onPicked(content);
  }

  void _pickGif(api.Attachment attachment) =>
      _pick(PictureStamp(attachment.id, animated: stampAnimates(attachment)));

  @override
  Widget build(BuildContext context) {
    final gifs = ref.watch(
      serverInfoProvider.select(
        (info) => info.valueOrNull?.gifSearchEnabled ?? false,
      ),
    );
    final tabs = [_StampTab.emoji, if (gifs) _StampTab.gifs, _StampTab.picture];
    final tab = tabs.contains(_tab) ? _tab : _StampTab.emoji;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.s8,
            AppSpacing.s8,
            AppSpacing.s8,
            AppSpacing.s4,
          ),
          child: AppSegmentedControl.inline(
            options: [
              for (final t in tabs) AppSegmentedOption(label: _label(t)),
            ],
            selectedIndex: tabs.indexOf(tab),
            onSegmentSelected: (i) => _select(tabs[i]),
            semanticLabel: 'What to stamp',
          ),
        ),
        SizedBox(
          height: _bodyHeight,
          child: KeyedSubtree(
            key: _body,
            child: switch (tab) {
              _StampTab.emoji => ComposerEmojiPicker(
                autofocusSearch: !widget.sheet,
                onSelect: (token) => _pick(
                  EmojiStamp(
                    storableEmoji(token, ref.read(customEmojiIndexProvider)),
                  ),
                ),
                onClose: () => Navigator.of(context).maybePop(),
              ),
              _StampTab.gifs => GifPickerBody(
                channelId: widget.channelId,
                focusSearch: !widget.sheet,
                fill: _bodyHeight != null,
                forStamp: true,
                onPicked: _pickGif,
              ),
              _StampTab.picture => StampPictureTab(
                channelId: widget.channelId,
                onPicked: _pick,
              ),
            },
          ),
        ),
      ],
    );
  }

  static String _label(_StampTab tab) => switch (tab) {
    _StampTab.emoji => 'Emoji',
    _StampTab.gifs => 'GIFs',
    _StampTab.picture => 'Picture',
  };
}
