// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer's own Emoji/GIFs picker: `composer_emoji_browse.dart`'s
/// `ComposerEmojiPicker` under an Emoji tab, `gif_picker.dart`'s
/// `GifPickerBody` under a GIFs tab, both inside one floating card.
/// `composer_picker_button.dart` anchors and opens this.
///
/// The Emoji tab is deliberately its own richer view rather than the shared
/// `EmojiPickerPanel` the hover-anchored reaction picker uses - see
/// `composer_emoji_browse.dart`'s own doc comment for why, and the PR body
/// for the blast-radius reasoning.
///
/// Stickers are deliberately absent. Nothing in this repo models a sticker -
/// no server type, no schema entry, no client model - so there is no tab for
/// one to hide behind. The configured GIF provider happens to expose a
/// stickers endpoint too, but adding a whole new media kind is a product
/// decision for the owner, not something to slip in alongside this fix.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'composer_emoji_browse.dart';
import 'emoji_picker_panel.dart' show pickerWidth;
import 'emoji_picker_sheets.dart' show SpaceEmojiSheetBody;
import 'gif_picker.dart' show GifPickerBody;
import '../providers/gif_preview_bytes.dart';
import '../providers/gif_trending.dart';

/// Which half of the panel is showing.
enum ComposerPickerTab { emoji, gif }

class ComposerPickerPanel extends StatefulWidget {
  const ComposerPickerPanel({
    super.key,
    required this.initialTab,
    required this.onSelectEmoji,
    required this.onPickedGif,
    required this.onClose,
    this.showGifTab = true,
    this.width = pickerWidth,
  });

  final ComposerPickerTab initialTab;
  final ValueChanged<String> onSelectEmoji;
  final ValueChanged<api.Attachment> onPickedGif;
  final VoidCallback onClose;

  /// Off for a deployment with no GIF provider configured, matching the
  /// button's own `gifSearchEnabled` gate: no tab for a feature that has
  /// nowhere to reach.
  final bool showGifTab;
  final double width;

  @override
  State<ComposerPickerPanel> createState() => _ComposerPickerPanelState();
}

class _ComposerPickerPanelState extends State<ComposerPickerPanel> {
  late ComposerPickerTab _tab = widget.initialTab;

  void _selectTab(int index) =>
      setState(() => _tab = ComposerPickerTab.values[index]);

  @override
  Widget build(BuildContext context) {
    final close = activatorFor(AppAction.escape);
    return CallbackShortcuts(
      // The emoji tab's own search/grid nav lives inside ComposerEmojiPicker.
      bindings: {if (close != null) close: widget.onClose},
      child: AppMenu(
        width: widget.width,
        children: _pickerBody(
          tab: _tab,
          onSelectTab: _selectTab,
          showGifTab: widget.showGifTab,
          // The richer pointer view; touch hosts SpaceEmojiSheetBody instead.
          emojiBody: ComposerEmojiPicker(
            width: widget.width,
            onSelect: widget.onSelectEmoji,
            onClose: widget.onClose,
          ),
          onPickedGif: widget.onPickedGif,
        ),
      ),
    );
  }
}

/// The tabs and whichever half they select, with no card around them.
///
/// Shared so the touch sheet and the pointer-anchored panel show the same
/// two tabs over the same two bodies: the panel wraps this in [AppMenu]'s
/// floating card, the sheet in [showAppSheet]'s. Duplicating the switch
/// would let one surface grow a tab the other never got.
List<Widget> _pickerBody({
  required ComposerPickerTab tab,
  required ValueChanged<int> onSelectTab,
  required bool showGifTab,
  required Widget emojiBody,
  required ValueChanged<api.Attachment> onPickedGif,
}) => [
  if (showGifTab) const _WarmTrendingGifs(),
  if (showGifTab)
    Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s8,
        AppSpacing.s8,
        AppSpacing.s8,
        AppSpacing.s4,
      ),
      child: AppSegmentedControl.inline(
        options: const [
          AppSegmentedOption(label: 'Emoji'),
          AppSegmentedOption(label: 'GIFs'),
        ],
        selectedIndex: ComposerPickerTab.values.indexOf(tab),
        onSegmentSelected: onSelectTab,
        semanticLabel: 'Emoji or GIFs',
      ),
    ),
  switch (tab) {
    ComposerPickerTab.emoji => emojiBody,
    ComposerPickerTab.gif => GifPickerBody(onPicked: onPickedGif),
  },
];

/// The same two tabs as a bottom sheet, for touch.
///
/// The composer used to offer only a Space-emoji sheet here, on the grounds
/// that the OS keyboard already carries every native emoji - true, but it
/// left GIFs with no entry point on a phone at all, which is what the owner
/// hit. Same tabs, same bodies, the surface `desktop-vs-mobile.md` rule 3
/// prescribes for touch.
Future<void> showComposerPickerSheet(
  BuildContext context, {
  required ValueChanged<String> onSelectEmoji,
  required ValueChanged<api.Attachment> onPickedGif,
  bool showGifTab = true,
}) {
  return showAppSheet<void>(
    context,
    builder: (context) => _ComposerPickerSheet(
      showGifTab: showGifTab,
      onSelectEmoji: onSelectEmoji,
      onPickedGif: onPickedGif,
    ),
  );
}

class _ComposerPickerSheet extends StatefulWidget {
  const _ComposerPickerSheet({
    required this.showGifTab,
    required this.onSelectEmoji,
    required this.onPickedGif,
  });

  final bool showGifTab;
  final ValueChanged<String> onSelectEmoji;
  final ValueChanged<api.Attachment> onPickedGif;

  @override
  State<_ComposerPickerSheet> createState() => _ComposerPickerSheetState();
}

class _ComposerPickerSheetState extends State<_ComposerPickerSheet> {
  ComposerPickerTab _tab = ComposerPickerTab.emoji;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: _pickerBody(
            tab: _tab,
            onSelectTab: (i) =>
                setState(() => _tab = ComposerPickerTab.values[i]),
            showGifTab: widget.showGifTab,
            // Space list only: a phone's keyboard already has every native emoji.
            emojiBody: SpaceEmojiSheetBody(
              onSelect: (emoji) {
                Navigator.of(context).pop();
                widget.onSelectEmoji(emoji);
              },
            ),
            onPickedGif: (attachment) {
              Navigator.of(context).pop();
              widget.onPickedGif(attachment);
            },
          ),
        ),
      ),
    );
  }
}

/// How many trending thumbnails to fetch before the GIFs tab opens: about one row.
const _warmThumbnails = 6;

/// Starts the trending fetch and its first thumbnails as the picker opens, so
/// switching to GIFs shows tiles at once; draws nothing.
class _WarmTrendingGifs extends ConsumerStatefulWidget {
  const _WarmTrendingGifs();

  @override
  ConsumerState<_WarmTrendingGifs> createState() => _WarmTrendingGifsState();
}

class _WarmTrendingGifsState extends ConsumerState<_WarmTrendingGifs> {
  @override
  void initState() {
    super.initState();
    _warm();
  }

  Future<void> _warm() async {
    try {
      final trending = await ref.read(trendingGifsProvider.future);
      if (!mounted) return;
      for (final gif in trending.take(_warmThumbnails)) {
        ref.read(gifPreviewBytesProvider(gif.id).future).ignore();
      }
    } on Object {
      // The GIFs tab shows its own error and retry when opened; a warm-up has nothing to say.
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
