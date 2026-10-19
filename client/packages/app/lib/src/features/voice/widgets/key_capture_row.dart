// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A settings row that shows a key cap and a Change button, then takes the
/// next key (or chord) pressed. Escape cancels; a refused key says why and
/// keeps waiting. Everything is reachable from the keyboard: Tab to Change,
/// Enter to start, press the key.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../settings/widgets/settings_detail_row.dart';
import '../../settings/widgets/settings_section_header.dart';
import '../providers/shortcut_overrides.dart';

/// The key pressed and the modifiers held with it.
class CapturedKey {
  const CapturedKey(
    this.key, {
    this.control = false,
    this.alt = false,
    this.shift = false,
    this.meta = false,
  });

  final LogicalKeyboardKey key;
  final bool control;
  final bool alt;
  final bool shift;
  final bool meta;

  /// Only for a key that is not itself a modifier.
  SingleActivator get activator => SingleActivator(
    key,
    control: control,
    alt: alt,
    shift: shift,
    meta: meta,
  );
}

/// Returns why the key was refused, or null once it has been taken.
typedef KeyCapture = String? Function(CapturedKey captured);

class KeyCaptureRow extends StatefulWidget {
  const KeyCaptureRow({
    super.key,
    required this.title,
    required this.keyCap,
    required this.semanticName,
    required this.onCapture,
    this.sub = false,
    this.modifiersAreKeys = false,
  });

  final String title;
  final String keyCap;

  /// What a screen reader calls the key, e.g. `Mute shortcut`.
  final String semanticName;
  final KeyCapture onCapture;

  /// Drawn as a compact child row of the group above it.
  final bool sub;

  /// A modifier on its own can be the key (push to talk), instead of waiting for the key it modifies.
  final bool modifiersAreKeys;

  @override
  State<KeyCaptureRow> createState() => _KeyCaptureRowState();
}

class _KeyCaptureRowState extends State<KeyCaptureRow> {
  final _capture = FocusNode(debugLabel: 'key capture');
  bool _listening = false;
  String? _refusal;

  @override
  void dispose() {
    _capture.dispose();
    super.dispose();
  }

  void _start() {
    setState(() {
      _listening = true;
      _refusal = null;
    });
    _capture.requestFocus();
  }

  void _stop() {
    if (!mounted) return;
    setState(() {
      _listening = false;
      _refusal = null;
    });
    _capture.unfocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_listening || event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _stop();
      return KeyEventResult.handled;
    }
    if (!widget.modifiersAreKeys && isModifierOnly(key)) {
      return KeyEventResult.handled;
    }
    final keyboard = HardwareKeyboard.instance;
    final captured = widget.modifiersAreKeys
        ? CapturedKey(key)
        : CapturedKey(
            key,
            control: keyboard.isControlPressed,
            alt: keyboard.isAltPressed,
            shift: keyboard.isShiftPressed,
            meta: keyboard.isMetaPressed,
          );
    final refusal = widget.onCapture(captured);
    if (refusal == null) {
      _stop();
    } else {
      setState(() => _refusal = refusal);
    }
    return KeyEventResult.handled;
  }

  String get _prompt =>
      _refusal ??
      (widget.modifiersAreKeys
          ? 'Press a key, or Escape to cancel'
          : 'Press the new shortcut, or Escape to cancel');

  Widget get _trailing => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: AppSpacing.s8,
    children: [
      if (!_listening)
        ShortcutKeyCap(
          label: widget.keyCap,
          semanticLabel: '${widget.semanticName}: ${widget.keyCap}',
        ),
      AppButton(
        label: _listening ? 'Cancel' : 'Change',
        size: AppButtonSize.sm,
        variant: AppButtonVariant.secondary,
        onPressed: _listening ? _stop : _start,
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final row = widget.sub
        ? SettingsSubRow(
            label: _listening ? _prompt : widget.title,
            trailing: _trailing,
          )
        : SettingsDetailRow(
            title: widget.title,
            detail: _listening ? _prompt : null,
            trailing: _trailing,
          );
    return Focus(
      focusNode: _capture,
      // Only the Change button is a tab stop; this node just holds focus while listening.
      skipTraversal: true,
      onKeyEvent: _onKey,
      onFocusChange: (focused) {
        if (!focused && _listening) _stop();
      },
      child: Semantics(liveRegion: _listening, child: row),
    );
  }
}

/// A key (or chord) drawn as a key cap.
class ShortcutKeyCap extends StatelessWidget {
  const ShortcutKeyCap({
    super.key,
    required this.label,
    required this.semanticLabel,
  });

  final String label;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Semantics(
      label: semanticLabel,
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minWidth: AppSizes.controlSm),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s8,
          vertical: AppSpacing.s4,
        ),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: tokens.surfaceSunken,
          border: Border.all(color: tokens.borderStrong),
          borderRadius: BorderRadius.circular(AppRadii.control),
        ),
        child: Text(
          label,
          style: AppText.caption.copyWith(
            fontFamily: AppFonts.mono,
            fontWeight: AppWeights.semi,
            color: tokens.textPrimary,
          ),
        ),
      ),
    );
  }
}
