// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [AuthorProfileTapTarget], split out of `message_row_identity.dart` to keep
/// that file to the row's own leading/header composition rather than this
/// wrapper's own semantics reasoning.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/user_profiles.dart';
import 'member_profile.dart';
import 'message_row_roving.dart';

/// Wraps [child] so a tap (or its own accessible action) opens [authorId]'s
/// profile - the exact popover [showMemberProfile] already opens from the
/// member pane - reusing [userProfileProvider], the same resolver
/// `UserAvatar` already uses for its own avatar cache key.
///
/// Absent entirely while there is nothing to open: a null [authorId] (an
/// anonymised author) or a profile that has not resolved yet skip the wrap
/// outright rather than offering a tap that would fail once pressed.
///
/// [child]'s own semantics are replaced by [semanticLabel], never merged with
/// it - `excludeSemantics: true` on the outer [Semantics] is what does that,
/// mutation-tested: without it a resolved avatar's label silently grew a
/// second line merged in from `AppAvatar`'s own built-in name label, the same
/// shape of bleed PR #370 ("54, the resize bar") records, found only
/// by dumping the real semantics tree, not by reading the widget.
/// `excludeFromSemantics` on the [GestureDetector] is redundant given that
/// (removing it alone changes nothing observable), kept anyway to match that
/// same entry's established shape: the recognizer should not describe itself
/// at all once an ancestor already owns the whole node.
class AuthorProfileTapTarget extends ConsumerStatefulWidget {
  const AuthorProfileTapTarget({
    super.key,
    required this.authorId,
    required this.semanticLabel,
    required this.child,
    this.decorativeWhenUnresolved = false,
    this.fingerTarget = false,
  });

  final String? authorId;
  final String semanticLabel;
  final Widget child;

  /// True keeps [child] excluded from the semantics tree while unresolved,
  /// for content that is decorative on its own (the avatar: the header
  /// beside it already names the author). False, the default, leaves
  /// [child]'s own semantics live in that state, for content that carries
  /// meaning on its own (the header's name text) until there is somewhere
  /// for a tap to actually go.
  final bool decorativeWhenUnresolved;

  /// True for the one control a finger presses to open the profile (the
  /// avatar): at touch density its hit area is padded to 44pt. False for the
  /// author name, which at 22pt tall cannot be padded without growing every
  /// message header, so a finger does not press it there; the avatar covers
  /// that, and the keyboard and screen readers still reach the name.
  final bool fingerTarget;

  @override
  ConsumerState<AuthorProfileTapTarget> createState() =>
      _AuthorProfileTapTargetState();
}

class _AuthorProfileTapTargetState
    extends ConsumerState<AuthorProfileTapTarget> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final id = widget.authorId;
    final profile = id == null
        ? null
        : ref.watch(userProfileProvider(id)).valueOrNull;
    if (profile == null) {
      return widget.decorativeWhenUnresolved
          ? ExcludeSemantics(child: widget.child)
          : widget.child;
    }

    final tokens = Theme.of(context).extension<AppTokens>()!;

    void open() => unawaited(showMemberProfile(context, profile: profile));

    final pressable = widget.fingerTarget || !AppTouchTargets.of(context);

    return AppTouchHitArea(
      touch: widget.fingerTarget ? null : false,
      alignment: Alignment.topLeft,
      child: RovingStop(
        builder: (context, node) => Semantics(
          button: true,
          label: widget.semanticLabel,
          excludeSemantics: true,
          onTap: open,
          child: FocusableActionDetector(
            focusNode: node,
            mouseCursor: pressable
                ? SystemMouseCursors.click
                : MouseCursor.defer,
            onShowFocusHighlight: (v) => setState(() => _focused = v),
            actions: <Type, Action<Intent>>{
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) => open(),
              ),
            },
            child: GestureDetector(
              onTap: pressable ? open : null,
              excludeFromSemantics: true,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  widget.child,
                  // Only mounted while focus-highlighted, so a pointer-only run draws nothing extra.
                  if (_focused)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: tokens.focusRing,
                              width: 2,
                            ),
                            borderRadius: BorderRadius.circular(
                              AppRadii.control,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
