// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Wraps the composer's field row: converts a typed `:name:` into its glyph
/// and previews the Space emoji a draft will render.
///
/// A sibling of `composer.dart` rather than part of it: that file is at its
/// line ceiling and this reacts only to the controller it is handed.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../emoji/providers/emoji_catalog_provider.dart';
import 'composer_shortcode_convert.dart';
import '../../emoji/widgets/custom_emoji_image.dart';

class ComposerShortcodes extends ConsumerStatefulWidget {
  const ComposerShortcodes({
    super.key,
    required this.controller,
    required this.child,
  });

  final TextEditingController controller;
  final Widget child;

  @override
  ConsumerState<ComposerShortcodes> createState() => _ComposerShortcodesState();
}

class _ComposerShortcodesState extends ConsumerState<ComposerShortcodes> {
  late String _previous = widget.controller.text;
  ShortcodeConversion? _converted;
  List<String> _previewNames = const [];

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
  }

  @override
  void didUpdateWidget(covariant ComposerShortcodes oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChange);
      widget.controller.addListener(_onChange);
      _previous = widget.controller.text;
      _converted = null;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  Set<String> get _spaceNames =>
      ref.read(customEmojiIndexProvider).keys.toSet();

  void _onChange() {
    final value = widget.controller.value;
    final text = value.text;
    if (text == _previous) return;
    final caret = value.selection.baseOffset;

    final undo = _converted == null
        ? null
        : undoConversion(conversion: _converted!, text: text, caret: caret);
    final conversion = undo != null
        ? null
        : convertCompletedShortcode(
            previous: _previous,
            text: text,
            caret: caret,
            spaceNames: _spaceNames,
          );

    _converted = conversion;
    if (undo != null) {
      _previous = undo.text;
      widget.controller.value = TextEditingValue(
        text: undo.text,
        selection: TextSelection.collapsed(offset: undo.caret),
      );
    } else if (conversion != null) {
      _previous = conversion.textAfter;
      widget.controller.value = TextEditingValue(
        text: conversion.textAfter,
        selection: TextSelection.collapsed(offset: conversion.end),
      );
    } else {
      _previous = text;
    }

    final names = spaceShortcodesIn(widget.controller.text, _spaceNames);
    if (names.join(',') != _previewNames.join(',')) {
      setState(() => _previewNames = names);
    }
  }

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(customEmojiIndexProvider);
    final names = _previewNames.where(index.containsKey).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (names.isNotEmpty) _Preview(names: names, index: index),
        widget.child,
      ],
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.names, required this.index});

  final List<String> names;
  final Map<String, String> index;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      key: const Key('composer-shortcode-preview'),
      padding: const EdgeInsets.only(left: 4, bottom: AppSpacing.s4),
      child: Wrap(
        spacing: AppSpacing.s12,
        runSpacing: AppSpacing.s4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final name in names)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CustomEmojiImage(
                  emojiId: index[name]!,
                  label: ':$name:',
                  size: AppSizes.icon20,
                ),
                const SizedBox(width: AppSpacing.s4),
                Text(
                  ':$name:',
                  style: AppText.caption.copyWith(
                    color: tokens.textSecondary,
                    fontFamily: AppFonts.mono,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
