// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A colour picker: a saturation/value square, a hue slider, a hex field and
/// a preview, with a confirm button (Save by default) and Cancel.
///
/// [showAppColourPicker] opens it with `showAppSheet`, so a bottom sheet on a
/// phone and a centred dialog on a desktop
/// (`docs/design/desktop-vs-mobile.md`, rule 4: a short task with a submit).
library;

import 'package:flutter/material.dart';

import '../../app_metrics.dart';
import '../../app_tokens.dart';
import '../../app_typography.dart';
import '../../colour_contrast.dart';
import '../../colour_hex.dart';
import '../core/button.dart';
import '../surfaces/sheet.dart';
import '../surfaces/sheet_header.dart';
import 'colour_picker_surfaces.dart';
import 'focusable_tap_target.dart' show focusRingGap, focusRingWidth;
import 'input.dart';

/// Opens the picker on [initial]. Resolves the saved colour, or null on cancel.
///
/// [caption] sits under [title]; [extraBuilder] adds a line under the hex field.
Future<Color?> showAppColourPicker(
  BuildContext context, {
  required Color initial,
  String title = 'Custom colour',
  String? caption,
  String confirmLabel = 'Save',
  ValueChanged<Color>? onChanged,
  ColourPickerExtraBuilder? extraBuilder,
}) =>
    showAppSheet<Color>(
      context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSheetHeader(title, caption: caption),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s16,
              0,
              AppSpacing.s16,
              AppSpacing.s16,
            ),
            child: AppColourPicker(
              initial: initial,
              confirmLabel: confirmLabel,
              onChanged: onChanged,
              extraBuilder: extraBuilder,
              onSave: (c) => Navigator.of(context).pop(c),
              onCancel: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    );

/// Builds a line under the hex field from the colour as it is dragged or typed.
typedef ColourPickerExtraBuilder = Widget Function(
  BuildContext context,
  Color colour,
);

/// The square and slider reserve a focus ring; the rows below line up with their edge.
const _ringInset =
    EdgeInsets.symmetric(horizontal: focusRingGap + focusRingWidth);

class AppColourPicker extends StatefulWidget {
  const AppColourPicker({
    super.key,
    required this.initial,
    required this.onSave,
    required this.onCancel,
    this.onChanged,
    this.confirmLabel = 'Save',
    this.confirmVariant = AppButtonVariant.primary,
    this.extraBuilder,
    this.beside = false,
  });

  static const hexFieldKey = Key('colour_picker_hex');
  static const confirmKey = Key('colour_picker_confirm');

  /// Called with each colour as it is dragged or typed, for a live preview.
  final ValueChanged<Color>? onChanged;

  final Color initial;
  final ValueChanged<Color> onSave;
  final VoidCallback onCancel;

  /// Names the button that keeps the colour: Done where the colour is part
  /// of a larger form that saves on its own.
  final String confirmLabel;
  final AppButtonVariant confirmVariant;

  /// Extra lines between the hex field and the buttons, rebuilt as the colour moves.
  final ColourPickerExtraBuilder? extraBuilder;

  /// The square and hue on the left, the fields and buttons on the right, for
  /// a picker opened inline in a wide form where height is short.
  final bool beside;

  @override
  State<AppColourPicker> createState() => _AppColourPickerState();
}

class _AppColourPickerState extends State<AppColourPicker> {
  late HSVColor _hsv = HSVColor.fromColor(widget.initial);
  late final _hex = TextEditingController(text: hexOfColour(widget.initial));
  String? _error;

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _fromSurface(HSVColor hsv) {
    setState(() {
      _hsv = hsv;
      _error = null;
      _hex.text = hexOfColour(hsv.toColor());
    });
    widget.onChanged?.call(hsv.toColor());
  }

  void _fromText(String text) {
    final colour = colourFromHexText(text);
    setState(() {
      _error = colour == null && text.trim().isNotEmpty
          ? 'Use a hex colour like #3A7BD5.'
          : null;
      if (colour == null) return;
      final parsed = HSVColor.fromColor(colour);
      final greyOrBlack = parsed.saturation == 0 || parsed.value == 0;
      _hsv = greyOrBlack ? parsed.withHue(_hsv.hue) : parsed;
    });
    if (colour != null) widget.onChanged?.call(colour);
  }

  Color? get _typed => colourFromHexText(_hex.text);

  void _save() {
    final colour = _typed;
    if (colour == null) {
      setState(() => _error = 'Use a hex colour like #3A7BD5.');
      return;
    }
    widget.onSave(colour);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final colour = _typed ?? _hsv.toColor();
    final surfaces = [
      AspectRatio(
        aspectRatio: widget.beside ? 2 : 1.8,
        child: SaturationValueSquare(hsv: _hsv, onChanged: _fromSurface),
      ),
      const SizedBox(height: AppSpacing.s12),
      HueSlider(hsv: _hsv, onChanged: _fromSurface),
    ];
    final fields = [
      Padding(
        padding: _ringInset,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: _inputRing),
              child:
                  _PreviewChip(colour: colour, surface: tokens.surfaceRaised),
            ),
            const SizedBox(width: AppSpacing.s12),
            Expanded(
              child: AppInput(
                key: AppColourPicker.hexFieldKey,
                controller: _hex,
                mono: true,
                autocorrect: false,
                semanticLabel: 'Hex colour',
                placeholder: '#RRGGBB',
                errorText: _error,
                onChanged: _fromText,
                onSubmitted: (_) => _save(),
              ),
            ),
          ],
        ),
      ),
      if (widget.extraBuilder case final extra?) ...[
        const SizedBox(height: AppSpacing.s12),
        Padding(padding: _ringInset, child: extra(context, colour)),
      ],
      const SizedBox(height: AppSpacing.s16),
      Padding(padding: _ringInset, child: _buttons()),
    ];
    if (!widget.beside) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...surfaces,
          const SizedBox(height: AppSpacing.s12),
          ...fields,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: AppSpacing.s16,
      children: [
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: surfaces,
          ),
        ),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: fields,
          ),
        ),
      ],
    );
  }

  Widget _buttons() => Row(
        mainAxisAlignment: MainAxisAlignment.end,
        spacing: AppSpacing.s8,
        children: [
          AppButton(
            label: 'Cancel',
            variant: AppButtonVariant.ghost,
            onPressed: widget.onCancel,
          ),
          AppButton(
            key: AppColourPicker.confirmKey,
            label: widget.confirmLabel,
            variant: widget.confirmVariant,
            disabled: _typed == null,
            onPressed: _save,
          ),
        ],
      );
}

/// Matches the hex field beside it.
const double _inputHeight = 38;

/// The focus ring `AppInput` reserves outside the border the chip lines up with.
const double _inputRing = 4;

class _PreviewChip extends StatelessWidget {
  const _PreviewChip({required this.colour, required this.surface});

  final Color colour;
  final Color surface;

  @override
  Widget build(BuildContext context) {
    final onColour = contrastRatio(colour, const Color(0xFFFFFFFF)) >= 4.5
        ? const Color(0xFFFFFFFF)
        : const Color(0xFF000000);
    return Semantics(
      label: 'Preview ${hexOfColour(colour)}',
      excludeSemantics: true,
      child: Container(
        width: 72,
        height: _inputHeight,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: colour,
          borderRadius: BorderRadius.circular(AppRadii.full),
          border: Border.all(
            color: nudgeForContrast(colour, surface),
            width: 2,
          ),
        ),
        child: Text('Aa', style: AppText.ui.copyWith(color: onColour)),
      ),
    );
  }
}
