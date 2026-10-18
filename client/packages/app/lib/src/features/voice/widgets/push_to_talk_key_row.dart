// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The push-to-talk key, as one compact row: the current key as a key cap
/// and a Change button that waits for the next key pressed. Escape cancels.
/// Any single key works. Whether it also works with another app focused is
/// the status line under the row, from the global hotkey source.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../settings/widgets/settings_section_header.dart';

/// Keys that already mean something while choosing, so they cannot be bound.
final _unbindable = {
  LogicalKeyboardKey.escape,
  LogicalKeyboardKey.tab,
  LogicalKeyboardKey.enter,
  LogicalKeyboardKey.numpadEnter,
};

/// Whether [key] can be the push-to-talk key.
bool canBindPushToTalk(LogicalKeyboardKey key) => !_unbindable.contains(key);

/// A short, readable name for [key] on its key cap.
String pushToTalkKeyName(LogicalKeyboardKey key) {
  final label = key.keyLabel.trim();
  if (label.isNotEmpty) return label.length == 1 ? label.toUpperCase() : label;
  return key.debugName ?? 'Key ${key.keyId}';
}

class PushToTalkKeyRow extends StatefulWidget {
  const PushToTalkKeyRow({
    super.key,
    required this.current,
    required this.onChanged,
  });

  final LogicalKeyboardKey current;
  final ValueChanged<LogicalKeyboardKey> onChanged;

  @override
  State<PushToTalkKeyRow> createState() => _PushToTalkKeyRowState();
}

class _PushToTalkKeyRowState extends State<PushToTalkKeyRow> {
  final _capture = FocusNode(debugLabel: 'push-to-talk key capture');
  bool _listening = false;

  @override
  void dispose() {
    _capture.dispose();
    super.dispose();
  }

  void _start() {
    setState(() => _listening = true);
    _capture.requestFocus();
  }

  void _stop() {
    if (!mounted) return;
    setState(() => _listening = false);
    _capture.unfocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_listening || event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _stop();
      return KeyEventResult.handled;
    }
    if (!canBindPushToTalk(key)) return KeyEventResult.handled;
    widget.onChanged(key);
    _stop();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _capture,
      onKeyEvent: _onKey,
      onFocusChange: (focused) {
        if (!focused && _listening) _stop();
      },
      child: SettingsSubRow(
        label: _listening ? 'Press a key, or Escape to cancel' : 'Key',
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: AppSpacing.s8,
          children: [
            if (!_listening)
              ShortcutKeyCap(
                label: pushToTalkKeyName(widget.current),
                semanticLabel:
                    'Push-to-talk key: ${pushToTalkKeyName(widget.current)}',
              ),
            AppButton(
              label: _listening ? 'Cancel' : 'Change',
              size: AppButtonSize.sm,
              variant: AppButtonVariant.secondary,
              onPressed: _listening ? _stop : _start,
            ),
          ],
        ),
      ),
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
