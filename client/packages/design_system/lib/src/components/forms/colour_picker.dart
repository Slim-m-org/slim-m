// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A colour picker: a saturation/value square, a hue slider, a hex field and
/// a preview, with Save and Cancel.
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
import 'colour_picker_surfaces.dart';
import 'focusable_tap_target.dart' show focusRingGap, focusRingWidth;
import 'input.dart';

/// Opens the picker on [initial]. Resolves the saved colour, or null on cancel.
Future<Color?> showAppColourPicker(
  BuildContext context, {
  required Color initial,
  String title = 'Custom colour',
}) =>
    showAppSheet<Color>(
      context,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.s16,
          0,
          AppSpacing.s16,
          AppSpacing.s16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: AppText.body.copyWith(
                color: Theme.of(context).extension<AppTokens>()!.textPrimary,
                fontWeight: AppWeights.semi,
              ),
            ),
            const SizedBox(height: AppSpacing.s12),
            AppColourPicker(
              initial: initial,
              onSave: (c) => Navigator.of(context).pop(c),
              onCancel: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
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
  });

  final Color initial;
  final ValueChanged<Color> onSave;
  final VoidCallback onCancel;

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

  void _fromSurface(HSVColor hsv) => setState(() {
        _hsv = hsv;
        _error = null;
        _hex.text = hexOfColour(hsv.toColor());
      });

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
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(
          aspectRatio: 1.8,
          child: SaturationValueSquare(hsv: _hsv, onChanged: _fromSurface),
        ),
        const SizedBox(height: AppSpacing.s12),
        HueSlider(hsv: _hsv, onChanged: _fromSurface),
        const SizedBox(height: AppSpacing.s12),
        Padding(
          padding: _ringInset,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _PreviewChip(colour: colour, surface: tokens.surfaceRaised),
              const SizedBox(width: AppSpacing.s12),
              Expanded(
                child: AppInput(
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
        const SizedBox(height: AppSpacing.s16),
        Padding(
          padding: _ringInset,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            spacing: AppSpacing.s8,
            children: [
              AppButton(
                label: 'Cancel',
                variant: AppButtonVariant.ghost,
                onPressed: widget.onCancel,
              ),
              AppButton(
                label: 'Save',
                variant: AppButtonVariant.primary,
                disabled: _typed == null,
                onPressed: _save,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Matches the hex field beside it.
const double _inputHeight = 38;

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
