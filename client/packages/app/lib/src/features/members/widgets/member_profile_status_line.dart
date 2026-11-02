// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The presence word and the typed status beside it, on a member's card. On
/// your own card it is also the way into the status menu.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'presence_indicator.dart';
import 'presence_menu.dart';

/// Finds the status edit pencil in tests.
const statusEditPencilKey = Key('member-status-edit-pencil');

/// "Online - joinkin it": what someone's state is, then what they typed.
///
/// [editable] makes the whole line a button for the status menu; the pencil
/// shows on hover, and always under [kCompactWidth], where nothing hovers.
class MemberProfileStatusLine extends StatefulWidget {
  const MemberProfileStatusLine({
    super.key,
    required this.presence,
    required this.statusText,
    this.editable = false,
  });

  final AppPresence presence;
  final String? statusText;
  final bool editable;

  @override
  State<MemberProfileStatusLine> createState() =>
      _MemberProfileStatusLineState();
}

class _MemberProfileStatusLineState extends State<MemberProfileStatusLine> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final presence = widget.presence;
    final word = presence.word;
    final secondary = AppText.caption.copyWith(color: tokens.textSecondary);
    final status = widget.statusText;
    final touch = MediaQuery.sizeOf(context).width < kCompactWidth;

    Widget line(bool showPencil) => Row(
      spacing: AppSpacing.s8,
      children: [
        if (word != null)
          PresenceIndicator(
            presence: presence,
            size: 8,
            backgroundColor: tokens.surfaceRaised,
          ),
        Text(_sentenceCase(word), style: secondary),
        if (status != null) Text('-', style: secondary),
        if (status != null)
          Flexible(
            child: Text(
              status,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption.copyWith(color: tokens.textPrimary),
            ),
          )
        else if (widget.editable)
          Text(
            'Set a status',
            style: secondary.copyWith(fontStyle: FontStyle.italic),
          ),
        if (widget.editable)
          Opacity(
            key: statusEditPencilKey,
            opacity: showPencil ? 1 : 0,
            child: ExcludeSemantics(
              child: Icon(
                AppIcons.edit,
                size: AppSizes.icon12,
                color: tokens.textSecondary,
              ),
            ),
          ),
      ],
    );

    if (!widget.editable) return line(false);
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
                child: line(touch || _hovered),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _sentenceCase(String? word) => word == null || word.isEmpty
    ? ''
    : word[0].toUpperCase() + word.substring(1);
