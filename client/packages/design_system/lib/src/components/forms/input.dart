// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A single-line text field. The source design fixes three heights (sm 32,
/// md 38, lg 44) and a constant body-size font across all three: size only
/// changes the row, never the type, matching the rest of this system's
/// "the row grows, nothing else about it changes" convention.
///
/// Focus is drawn as two rings: the inner 1px border swaps to accent-fill and
/// the 2px ring outside it is accent-ring. Neither is `focusRing`, because the
/// source design authors this control's own focus treatment explicitly (a
/// `focused` prop), unlike the other form controls, which do not model focus at
/// all and so fall back to this package's own accessibility ring.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextInputFormatter;

import '../../app_icons.dart';
import '../../app_metrics.dart';
import '../../app_tokens.dart';
import '../../app_typography.dart';
import '../../text_context_menu.dart';
import '../core/icon_button.dart';
import 'code_point_limit.dart';

enum AppInputSize { sm, md, lg }

class AppInput extends StatefulWidget {
  const AppInput({
    super.key,
    this.controller,
    this.focusNode,
    this.placeholder,
    this.size = AppInputSize.md,
    this.icon,
    this.trailing,
    this.errorText,
    this.enabled = true,
    this.mono = false,
    this.obscureText = false,
    this.autofocus = false,
    this.keyboardType,
    this.textInputAction,
    this.inputFormatters,
    this.maxLength,
    this.counterMax,
    this.autofillHints,
    this.autocorrect = true,
    this.onChanged,
    this.onSubmitted,
    this.semanticLabel,
    this.minLines,
    this.maxLines,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? placeholder;
  final AppInputSize size;

  /// A leading glyph, built by the caller rather than by this widget: the
  /// source component renders `icon` as an already-built node, not a raw
  /// glyph it sizes and colours itself.
  final Widget? icon;

  /// A widget placed after the text, such as a keyboard-shortcut hint or a
  /// clear button. Also caller-built, for the same reason as [icon], and
  /// because a `Kbd` component belongs to `components/core`, not here.
  final Widget? trailing;

  /// Not in the source design, which has no error state at all. Kept because
  /// a form field without one is not viable; it borrows [AppTokens.dangerText]
  /// and [AppTokens.dangerBorder] rather than inventing new colours.
  final String? errorText;
  final bool enabled;

  /// Switches to `--font-mono`, used for invite codes and server addresses.
  final bool mono;
  final bool obscureText;
  final bool autofocus;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;

  /// Rejects a keystroke before it ever becomes a character in the field,
  /// which is the only place a caller can refuse "not a digit" outright
  /// rather than accepting it and parsing the mistake out later.
  final List<TextInputFormatter>? inputFormatters;

  /// The most characters the field takes, matching the server's cap for it, so
  /// a value the server would refuse cannot be typed or pasted in.
  final int? maxLength;

  /// A soft limit: typing may run past it, and a counter under the field turns
  /// red when it does so the caller's save check can refuse with a reason.
  final int? counterMax;

  /// Passed straight through to the platform's autofill, so a password
  /// manager can recognise a credential field drawn in this chrome.
  final Iterable<String>? autofillHints;
  final bool autocorrect;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final String? semanticLabel;

  /// Setting either makes the field grow with its text between these bounds
  /// instead of holding one fixed-height line.
  final int? minLines;
  final int? maxLines;

  @override
  State<AppInput> createState() => _AppInputState();
}

class _AppInputState extends State<AppInput> {
  late final FocusNode _focusNode;
  bool _ownsFocusNode = false;
  bool _focused = false;
  bool _revealed = false;

  @override
  void initState() {
    super.initState();
    _ownsFocusNode = widget.focusNode == null;
    _focusNode = widget.focusNode ?? FocusNode();
    _focusNode.addListener(_handleFocusChange);
  }

  void _handleFocusChange() => setState(() => _focused = _focusNode.hasFocus);

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    if (_ownsFocusNode) _focusNode.dispose();
    super.dispose();
  }

  /// The design's three sizes (32/38/44) do not line up with any existing
  /// AppSizes control-height token (controlMd is 34, controlLg is 38, and
  /// there is no 32 or 44 step besides rowTouch, which is a hit-target floor
  /// rather than a size). Reported as a token gap rather than bent to fit;
  /// these are the design's own numbers.
  double get _height => switch (widget.size) {
        AppInputSize.sm => 32,
        AppInputSize.md => 38,
        AppInputSize.lg => 44,
      };

  // Only read when there is no controller to listen to instead.
  String _uncontrolledText = '';

  void _onChanged(String value) {
    if (widget.counterMax != null && widget.controller == null) {
      setState(() => _uncontrolledText = value);
    }
    widget.onChanged?.call(value);
  }

  Widget _counter(AppTokens tokens, int max) {
    Widget count(String text) {
      final length = inputCharCount(text);
      return Text(
        '$length/$max',
        style: AppText.micro.copyWith(
          color: length > max ? tokens.dangerText : tokens.textSecondary,
        ),
      );
    }

    final controller = widget.controller;
    return Align(
      alignment: Alignment.centerRight,
      child: controller == null
          ? count(_uncontrolledText)
          : ListenableBuilder(
              listenable: controller,
              builder: (context, _) => count(controller.text),
            ),
    );
  }

  bool get _multiline => widget.minLines != null || widget.maxLines != null;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final hasError = (widget.errorText ?? '').isNotEmpty;

    return Semantics(
      label: widget.obscureText ? null : widget.semanticLabel,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ring(tokens, _field(tokens, hasError)),
          if (widget.counterMax case final max?) ...[
            const SizedBox(height: AppSpacing.s4),
            // Its own node, so the count never merges into the field's label.
            Semantics(container: true, child: _counter(tokens, max)),
          ],
          if (hasError) ...[
            const SizedBox(height: AppSpacing.s4),
            Text(
              widget.errorText!,
              style: AppText.caption.copyWith(
                  color: tokens.dangerText, fontFamily: AppFonts.sans),
            ),
          ],
        ],
      ),
    );
  }

  // Accent-fill on focus, not `focusRing`: this control authors its own focus
  // treatment. See the library doc at the top of the file.
  Color _borderColor(AppTokens tokens, bool hasError) {
    if (!widget.enabled) return tokens.borderSubtle;
    if (hasError) return tokens.dangerBorder;
    return _focused ? tokens.accentFill : tokens.borderStrong;
  }

  Widget _field(AppTokens tokens, bool hasError) {
    final textStyle = AppText.body.copyWith(
      color: tokens.textPrimary,
      fontFamily: widget.mono ? AppFonts.mono : AppFonts.sans,
    );

    return Container(
      // A floor, not a fixed height: at a large text scale the line outgrows 38.
      constraints: _multiline ? null : BoxConstraints(minHeight: _height),
      padding: EdgeInsets.symmetric(
        horizontal: AppSpacing.s12,
        vertical: _multiline ? AppSpacing.s8 : 0,
      ),
      decoration: BoxDecoration(
        color: widget.enabled ? tokens.surfaceRaised : tokens.surfaceSunken,
        borderRadius: BorderRadius.circular(AppRadii.control),
        border: Border.all(color: _borderColor(tokens, hasError)),
      ),
      child: Row(
        children: [
          if (widget.icon != null) ...[
            widget.icon!,
            const SizedBox(width: AppSpacing.s8)
          ],
          // The reveal toggle is its own node, so the label must sit on the field itself.
          Expanded(
            child: widget.obscureText
                ? Semantics(
                    label: widget.semanticLabel,
                    child: _textField(tokens, textStyle),
                  )
                : _textField(tokens, textStyle),
          ),
          if (widget.obscureText) ...[
            const SizedBox(width: AppSpacing.s8),
            _revealToggle(),
          ],
          if (widget.trailing != null) ...[
            const SizedBox(width: AppSpacing.s8),
            widget.trailing!
          ],
        ],
      ),
    );
  }

  Widget _revealToggle() => AppIconButton(
        icon: _revealed ? AppIcons.hideSecret : AppIcons.revealSecret,
        semanticLabel: _revealed ? 'Hide password' : 'Show password',
        tooltip: _revealed ? 'Hide password' : 'Show password',
        size: AppIconButtonSize.sm,
        iconSize: AppSizes.icon16,
        onPressed: widget.enabled
            ? () => setState(() => _revealed = !_revealed)
            : null,
      );

  Widget _textField(AppTokens tokens, TextStyle textStyle) {
    return TextField(
      controller: widget.controller,
      focusNode: _focusNode,
      // Live Text is noise in every field here; see its own library.
      contextMenuBuilder: textContextMenuWithoutScanText,
      enabled: widget.enabled,
      obscureText: widget.obscureText && !_revealed,
      minLines: widget.minLines,
      maxLines: _multiline ? widget.maxLines : 1,
      autofocus: widget.autofocus,
      keyboardType: widget.keyboardType,
      textInputAction: widget.textInputAction,
      inputFormatters: [
        ...?widget.inputFormatters,
        if (widget.maxLength case final max?) CodePointLengthLimit(max),
      ],
      autofillHints: widget.autofillHints,
      autocorrect: widget.autocorrect,
      onChanged: _onChanged,
      onSubmitted: widget.onSubmitted,
      style: textStyle,
      cursorColor: tokens.accentFill,
      decoration: InputDecoration(
        isDense: true,
        border: InputBorder.none,
        // The inner field opts out of the global boxed-input theme
        // entirely: this component draws its own chrome.
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        filled: false,
        hintText: widget.placeholder,
        hintStyle: textStyle.copyWith(color: tokens.textSecondary),
        contentPadding: EdgeInsets.zero,
      ),
    );
  }

  // The 2px ring is reserved space regardless of focus, coloured only when
  // focused, so gaining focus never shifts layout.
  Widget _ring(AppTokens tokens, Widget field) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        border: Border.all(
          color: _focused && widget.enabled
              ? tokens.accentRing
              : Colors.transparent,
          width: 2,
        ),
        borderRadius: BorderRadius.circular(AppRadii.control + 2),
      ),
      // The whole box is the target; the text line alone left most of it dead to a tap.
      child: MouseRegion(
        cursor: widget.enabled ? SystemMouseCursors.text : MouseCursor.defer,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // The field inside already says everything a screen reader needs.
          excludeFromSemantics: true,
          onTap: widget.enabled ? _focusNode.requestFocus : null,
          child: field,
        ),
      ),
    );
  }
}
