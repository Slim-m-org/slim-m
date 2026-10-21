// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Everyone in the call as overlapping avatars that open a list, since a person with no camera or share has no tile (decision 0086).
/// Each row opens the same menu a call tile has.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../../widgets/context_menu_focus.dart';
import '../../members/providers/blocks_controller.dart';
import '../../voice/providers/call_solo.dart';
import '../../voice/providers/voice_flags.dart';
import 'canvas_participants_sheet.dart';
import 'canvas_pill_surface.dart';
import 'canvas_roster_avatar.dart';

const int _shownInPill = 3;
const double _popoverWidth = 280;

/// Speakers first, so the person talking is never the one folded into "+n".
List<VoiceParticipant> _speakersFirst(List<VoiceParticipant> all) => [
  ...all.where((p) => p.isSpeaking),
  ...all.where((p) => !p.isSpeaking),
];

class CanvasRosterCluster extends ConsumerStatefulWidget {
  const CanvasRosterCluster({super.key});

  @override
  ConsumerState<CanvasRosterCluster> createState() =>
      _CanvasRosterClusterState();
}

class _CanvasRosterClusterState extends ConsumerState<CanvasRosterCluster> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  final _open = ValueNotifier<bool>(false);

  void _hide() {
    _portal.hide();
    _open.value = false;
  }

  // Desktop-vs-mobile rule 3: an anchored popover on a wide pane, a bottom sheet below kCompactWidth.
  void _toggle() {
    if (MediaQuery.sizeOf(context).width < kCompactWidth) {
      unawaited(showCanvasParticipantsSheet(context));
      return;
    }
    _portal.toggle();
    _open.value = _portal.isShowing;
  }

  @override
  void dispose() {
    _open.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final blocks = ref.watch(blocksProvider);
    final people = [
      for (final p in ref.watch(voiceParticipantsProvider))
        if (!blocks.contains(p.identity)) p,
    ];
    if (!ref.watch(callHasOthersProvider) || people.isEmpty) {
      return const SizedBox.shrink();
    }
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: (_) => _popover(people),
        child: ValueListenableBuilder<bool>(
          valueListenable: _open,
          builder: (context, open, _) => _trigger(context, people, open),
        ),
      ),
    );
  }

  Widget _trigger(
    BuildContext context,
    List<VoiceParticipant> people,
    bool open,
  ) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final ordered = _speakersFirst(people);
    final shown = ordered.take(_shownInPill).toList();
    final more = people.length - shown.length;
    const size = AppAvatarSize.s20;
    const step = size - AppSpacing.s4;
    return Semantics(
      container: true,
      button: true,
      expanded: open,
      label: 'In this call, ${people.length} people',
      excludeSemantics: true,
      onTap: _toggle,
      child: Tooltip(
        message: 'People in this call',
        excludeFromSemantics: true,
        child: CanvasPillSurface(
          tokens: tokens,
          onTap: _toggle,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: AppSizes.icon28),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: size + step * (shown.length - 1),
                    height: size,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        for (var i = 0; i < shown.length; i++)
                          Positioned(
                            left: i * step,
                            child: CanvasRosterAvatar(
                              key: ValueKey(shown[i].identity),
                              participant: shown[i],
                              size: size,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (more > 0) ...[
                    const SizedBox(width: AppSpacing.s4),
                    Text(
                      '+$more',
                      style: AppText.caption.copyWith(
                        color: tokens.textSecondary,
                        fontWeight: AppWeights.medium,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // A barrier under the list, so a click outside closes it without reaching the board or a menu opened from a row.
  Widget _popover(List<VoiceParticipant> people) {
    final width = MediaQuery.sizeOf(context).width - 2 * AppSpacing.s12;
    return Positioned.fill(
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _hide,
              onSecondaryTap: _hide,
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            child: CompositedTransformFollower(
              link: _link,
              showWhenUnlinked: false,
              targetAnchor: Alignment.bottomLeft,
              followerAnchor: Alignment.topLeft,
              offset: const Offset(0, AppSpacing.s4),
              child: ContextMenuKeyboardScope(
                onDismiss: _hide,
                child: AppMenu(
                  width: width < _popoverWidth ? width : _popoverWidth,
                  maxHeight: MediaQuery.sizeOf(context).height / 2,
                  children: [
                    const AppMenuLabel('In this call'),
                    for (final p in people)
                      CanvasParticipantRow(
                        key: ValueKey(p.identity),
                        participant: p,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
