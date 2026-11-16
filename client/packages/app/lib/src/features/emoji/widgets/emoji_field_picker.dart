// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A text field's emoji button, for a field that usually sits in a sheet
/// already: the anchored panel on a pointer width, and on compact the panel
/// inline under the field, so picking never stacks a second modal.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../routing/breakpoints.dart';
import 'emoji_picker.dart';

class EmojiFieldPicker extends StatefulWidget {
  const EmojiFieldPicker({
    super.key,
    required this.semanticLabel,
    required this.onSelect,
    required this.builder,
  });

  /// The button's name, saying which field it inserts into.
  final String semanticLabel;
  final ValueChanged<String> onSelect;

  /// Lays the field out with [button] wherever it belongs; the inline panel
  /// opens under all of it.
  final Widget Function(BuildContext context, Widget button) builder;

  @override
  State<EmojiFieldPicker> createState() => _EmojiFieldPickerState();
}

class _EmojiFieldPickerState extends State<EmojiFieldPicker> {
  bool _inline = false;

  void _setInline(bool open) => setState(() => _inline = open);

  void _pickInline(String emoji) {
    _setInline(false);
    widget.onSelect(emoji);
  }

  Widget _glyph(VoidCallback onPressed, {bool? active}) => AppIconButton(
    icon: AppIcons.smile,
    semanticLabel: widget.semanticLabel,
    tooltip: active == null ? 'Insert emoji' : null,
    active: active,
    onPressed: onPressed,
  );

  @override
  Widget build(BuildContext context) {
    final compact = LayoutClass.of(context) == LayoutClass.compact;
    final button = compact
        ? _glyph(() => _setInline(!_inline), active: _inline)
        : EmojiPickerButton(
            onSelect: widget.onSelect,
            triggerBuilder: (context, toggle) => _glyph(toggle),
          );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        widget.builder(context, button),
        AppRevealBand(
          child: compact && _inline
              ? Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.s8),
                  child: LayoutBuilder(
                    builder: (context, constraints) => EmojiPickerPanel(
                      autofocusSearch: false,
                      floating: false,
                      width: constraints.maxWidth,
                      onSelect: _pickInline,
                      onClose: () => _setInline(false),
                    ),
                  ),
                )
              : null,
        ),
      ],
    );
  }
}
