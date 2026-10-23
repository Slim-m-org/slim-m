// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The `@username` line of a member card, with a copy button after the handle.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/toasts.dart';

/// The copy icon shows on hover or focus, and always at touch density, where
/// there is no hover to reveal it. It stays focusable while hidden.
class MemberHandleLine extends ConsumerStatefulWidget {
  const MemberHandleLine({
    super.key,
    required this.username,
    required this.extras,
    required this.style,
  });

  final String username;

  /// Pronouns and the like, drawn after the copy button.
  final List<String> extras;
  final TextStyle style;

  @override
  ConsumerState<MemberHandleLine> createState() => _MemberHandleLineState();
}

class _MemberHandleLineState extends ConsumerState<MemberHandleLine> {
  bool _hovered = false;
  bool _focused = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: '@${widget.username}'));
    ref
        .read(toastsProvider.notifier)
        .show('Username copied.', severity: AppToastSeverity.success);
  }

  @override
  Widget build(BuildContext context) {
    final touch = AppTouchTargets.of(context);
    final visible = _hovered || _focused || touch;
    final button = AppIconButton(
      icon: AppIcons.copy,
      semanticLabel: 'Copy username',
      tooltip: 'Copy username',
      size: AppIconButtonSize.sm,
      iconSize: AppSizes.icon16,
      onPressed: _copy,
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              '@${widget.username}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: widget.style.merge(
                AppText.code.copyWith(fontSize: AppText.caption.fontSize),
              ),
            ),
          ),
          Focus(
            canRequestFocus: false,
            onFocusChange: (focused) => setState(() => _focused = focused),
            child: Opacity(
              opacity: visible ? 1 : 0,
              // A hidden icon is still the way a screen reader copies the handle.
              alwaysIncludeSemantics: true,
              child: touch ? button : _lineHigh(button),
            ),
          ),
          if (widget.extras.isNotEmpty)
            Flexible(
              child: Text(
                ' · ${widget.extras.join(' · ')}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: widget.style,
              ),
            ),
        ],
      ),
    );
  }
}

/// With a mouse the copy button is drawn at full size but lays out no taller than the handle, so the card's lines stay together.
Widget _lineHigh(Widget button) => SizedBox(
  width: AppSizes.controlSm,
  height: _handleLineHeight,
  child: OverflowBox(
    maxWidth: AppSizes.controlSm,
    maxHeight: AppSizes.controlSm,
    child: button,
  ),
);

const double _handleLineHeight = AppSizes.icon16 + AppSpacing.s4;
