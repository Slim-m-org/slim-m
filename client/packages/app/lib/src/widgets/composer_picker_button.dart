// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer's own entry point into `composer_picker_panel.dart`: one
/// smile button that toggles a floating panel anchored above it and
/// right-aligned, the same anchored-overlay shape `emoji_picker.dart`'s
/// `EmojiPickerButton` uses for the reaction picker below a message. The
/// panel's own tab strip carries the emoji or GIF choice (GIF only when this
/// deployment has search enabled).
///
/// Desktop-only: `composer_action_bar.dart` renders this at
/// `kCompactWidth` and above and falls back to the existing bottom sheets
/// below it, where the OS keyboard is still the better answer for native
/// emoji - desktop-vs-mobile.md rule 3 ("info about a thing plus its
/// actions" -> an anchored popover on a pointer, a bottom sheet on touch).
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import 'animated_menu_portal.dart';
import 'composer_picker_layout.dart';
import 'composer_picker_panel.dart';
import 'message_context_menu_layout.dart' show menuScreenMargin;

class ComposerPickerButton extends StatefulWidget {
  const ComposerPickerButton({
    super.key,
    required this.gifSearchEnabled,
    required this.onSelectEmoji,
    required this.onPickedGif,
  });

  final bool gifSearchEnabled;
  final ValueChanged<String> onSelectEmoji;
  final ValueChanged<api.Attachment> onPickedGif;

  @override
  State<ComposerPickerButton> createState() => _ComposerPickerButtonState();
}

class _ComposerPickerButtonState extends State<ComposerPickerButton> {
  final _controller = AnimatedMenuController();
  Offset _anchor = Offset.zero;

  /// Closes the panel if it is open, otherwise opens it above this button.
  void _toggle() {
    if (_controller.isShowing) {
      _controller.hide();
      return;
    }
    setState(() => _anchor = _anchorOffset());
    _controller.show();
  }

  void _close() => _controller.hide();

  /// This widget's own top-right corner, in the overlay's coordinate space:
  /// [ComposerPickerLayout] lands the panel's bottom-right there, its own
  /// gap above it.
  Offset _anchorOffset() {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final box = context.findRenderObject() as RenderBox?;
    if (overlay == null || box == null) return Offset.zero;
    return box.localToGlobal(Offset(box.size.width, 0), ancestor: overlay);
  }

  void _selectEmoji(String emoji) {
    _close();
    widget.onSelectEmoji(emoji);
  }

  void _pickedGif(api.Attachment attachment) {
    _close();
    widget.onPickedGif(attachment);
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _controller.portal,
      overlayChildBuilder: (context) => Positioned.fill(
        child: CustomSingleChildLayout(
          delegate: ComposerPickerLayout(
            anchor: _anchor,
            padding:
                MediaQuery.paddingOf(context) +
                const EdgeInsets.all(menuScreenMargin),
          ),
          child: AnimatedMenuSurface(
            controller: _controller,
            alignment: Alignment.bottomRight,
            child: TapRegion(
              onTapOutside: (_) => _close(),
              child: ComposerPickerPanel(
                initialTab: ComposerPickerTab.emoji,
                showGifTab: widget.gifSearchEnabled,
                onSelectEmoji: _selectEmoji,
                onPickedGif: _pickedGif,
                onClose: _close,
              ),
            ),
          ),
        ),
      ),
      // One button, not one per tab; the tabs already carry that choice.
      child: AppIconButton(
        icon: AppIcons.smile,
        semanticLabel: widget.gifSearchEnabled
            ? 'Insert emoji or a GIF'
            : 'Insert emoji',
        tooltip: widget.gifSearchEnabled
            ? 'Insert emoji or a GIF'
            : 'Insert emoji',
        onPressed: _toggle,
      ),
    );
  }
}
