// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Makes a reaction chip answer "who left this?": holding it, or right-clicking
/// it, opens the list, and resting a mouse on it summarises the first names.
///
/// The chip's own tap is untouched, so a plain tap still toggles the viewer's
/// reaction. The hover summary is only ever a hint: the full list is one
/// long-press away on touch, which is what the desktop-vs-mobile guide asks of
/// every hover affordance.
library;

import 'dart:async';

import 'package:flutter/gestures.dart' show PointerEnterEvent, PointerExitEvent;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../providers/reaction_users.dart';
import '../providers/user_profiles.dart';
import 'context_menu_focus.dart';
import 'reaction_users_list.dart';
import 'reaction_users_surface.dart';

/// How long the pointer rests before the names are fetched, so sweeping across
/// a row of chips does not ask the server about each one.
const Duration reactionHoverRest = Duration(milliseconds: 250);

class ReactionChipWho extends ConsumerStatefulWidget {
  const ReactionChipWho({
    super.key,
    required this.messageId,
    required this.reaction,
    required this.customEmoji,
    required this.child,
  });

  final String messageId;
  final api.ReactionSummary reaction;
  final Map<String, String> customEmoji;
  final Widget child;

  @override
  ConsumerState<ReactionChipWho> createState() => _ReactionChipWhoState();
}

class _ReactionChipWhoState extends ConsumerState<ReactionChipWho> {
  Timer? _rest;
  bool _fetching = false;

  void _enter(PointerEnterEvent _) {
    _rest?.cancel();
    _rest = Timer(reactionHoverRest, () {
      if (mounted) setState(() => _fetching = true);
    });
  }

  void _exit(PointerExitEvent _) {
    _rest?.cancel();
    if (_fetching) setState(() => _fetching = false);
  }

  void _open() => unawaited(
    showReactionUsers(
      context,
      messageId: widget.messageId,
      reaction: widget.reaction,
      customEmoji: widget.customEmoji,
    ),
  );

  /// The names once the first few are known, the bare count until then.
  String _summary() {
    final total = widget.reaction.count;
    if (!_fetching) return reactionSummaryLine(const [], total);
    final key = (messageId: widget.messageId, emoji: widget.reaction.emoji);
    final ids = ref.watch(reactionUsersProvider(key)).userIds;
    if (ids == null) return reactionSummaryLine(const [], total);
    final named = ids.take(total <= 3 ? total : 2).toList();
    resolveAuthorProfiles(ref, named);
    final profiles = ref.watch(batchProfilesControllerProvider);
    if (!named.every(profiles.containsKey)) {
      return reactionSummaryLine(const [], total);
    }
    return reactionSummaryLine(reactionUserNames(ids, profiles), total);
  }

  @override
  void dispose() {
    _rest?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onLongPress: _open,
    // Up, not down: down fires for every nested recognizer.
    onSecondaryTapUp: (_) => _open(),
    child: MouseRegion(
      onEnter: _enter,
      onExit: _exit,
      child: Tooltip(
        message: _summary(),
        triggerMode: TooltipTriggerMode.manual,
        waitDuration: const Duration(milliseconds: 500),
        excludeFromSemantics: true,
        // The chip is its own tab stop; the keyboard route rides it.
        child: ContextMenuFocus(
          ownsFocusNode: false,
          onOpen: _open,
          child: widget.child,
        ),
      ),
    ),
  );
}
