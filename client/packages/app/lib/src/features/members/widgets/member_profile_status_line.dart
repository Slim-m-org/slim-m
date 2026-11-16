// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The status a member typed, one line under their name on their card. On
/// your own card it is also the way into the status menu.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_design_system/design_system.dart';

import 'presence_menu.dart';

/// Finds the status edit pencil in tests.
const statusEditPencilKey = Key('member-status-edit-pencil');

/// What someone typed, such as "joinkin it"; their presence is the dot on
/// their avatar, not a word here.
///
/// [editable] makes the whole line a button for the status menu, an anchored
/// dropdown per desktop-vs-mobile.md surface rule 2. The pencil shows on hover
/// or keyboard focus, and always under [kCompactWidth] (law 3: a hover
/// affordance needs a touch equivalent), where the row is 44dp tall (law 2).
class MemberProfileStatusLine extends StatefulWidget {
  const MemberProfileStatusLine({
    super.key,
    required this.statusText,
    this.editable = false,
  });

  /// Null draws nothing on someone else's card, and a prompt to write one on your own.
  final String? statusText;
  final bool editable;

  @override
  State<MemberProfileStatusLine> createState() =>
      _MemberProfileStatusLineState();
}

class _MemberProfileStatusLineState extends State<MemberProfileStatusLine> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    if (!widget.editable) return _line(tokens, false);
    final touch = MediaQuery.sizeOf(context).width < kCompactWidth;
    return PresenceMenuAnchor(
      targetAnchor: Alignment.bottomLeft,
      followerAnchor: Alignment.topLeft,
      offset: const Offset(0, 4),
      builder: (context, open) => MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        cursor: SystemMouseCursors.click,
        child: Semantics(
          button: true,
          label: 'Change your status',
          excludeSemantics: true,
          onTap: open,
          child: FocusableActionDetector(
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
              SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
            },
            onFocusChange: (v) => setState(() => _focused = v),
            actions: {
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  open();
                  return null;
                },
              ),
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: open,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: touch ? AppSizes.rowTouch : 0,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  heightFactor: 1,
                  child: _line(tokens, touch || _hovered || _focused),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _line(AppTokens tokens, bool showPencil) {
    final status = widget.statusText;
    if (status == null && !widget.editable) return const SizedBox.shrink();
    return Row(
      spacing: AppSpacing.s8,
      children: [
        Flexible(
          child: status == null
              ? Text(
                  'Set a status',
                  style: AppText.caption.copyWith(
                    color: tokens.textSecondary,
                    fontStyle: FontStyle.italic,
                  ),
                )
              : Text(
                  status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(color: tokens.textPrimary),
                ),
        ),
        if (widget.editable) _pencil(tokens, showPencil),
      ],
    );
  }

  Widget _pencil(AppTokens tokens, bool showPencil) => Opacity(
    key: statusEditPencilKey,
    opacity: showPencil ? 1 : 0,
    child: ExcludeSemantics(
      child: Icon(
        AppIcons.edit,
        size: AppSizes.icon12,
        color: tokens.textSecondary,
      ),
    ),
  );
}
