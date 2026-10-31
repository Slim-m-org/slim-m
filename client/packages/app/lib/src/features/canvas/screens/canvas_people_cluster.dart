// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Everyone here as overlapping avatars that open the one people list: call, follow and summon (decisions 0086 and 0095).
/// A person with no camera or share has no tile, so this is where they are.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/context_menu_focus.dart';
import '../../members/widgets/user_avatar.dart';
import '../widgets/canvas_pill_surface.dart';
import '../widgets/canvas_roster_avatar.dart';
import 'canvas_people_panel.dart';
import 'canvas_people_session.dart';
import 'canvas_people_sheet.dart';

const int _shownInPill = 3;
const double _popoverWidth = 280;

/// The followed person, then speakers, so neither is ever folded into "+n".
List<CanvasPerson> _shownFirst(List<CanvasPerson> all, String? followed) {
  bool speaking(CanvasPerson p) => p.participant?.isSpeaking ?? false;
  bool followedBy(CanvasPerson p) => p.id == followed;
  return [
    ...all.where(followedBy),
    ...all.where((p) => !followedBy(p) && speaking(p)),
    ...all.where((p) => !followedBy(p) && !speaking(p)),
  ];
}

class CanvasPeopleCluster extends ConsumerStatefulWidget {
  const CanvasPeopleCluster({super.key});

  @override
  ConsumerState<CanvasPeopleCluster> createState() =>
      _CanvasPeopleClusterState();
}

class _CanvasPeopleClusterState extends ConsumerState<CanvasPeopleCluster> {
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
      unawaited(showCanvasPeopleSheet(context));
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
    final session = CanvasPeopleScope.maybeOf(context);
    final people = canvasPeople(
      call: ref.watch(canvasCallPeopleProvider),
      onCanvas: session?.onCanvas ?? const [],
    );
    if (!people.any((p) => !p.isSelf)) return const SizedBox.shrink();
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: (_) => _popover(),
        child: ValueListenableBuilder<bool>(
          valueListenable: _open,
          builder: (context, open, _) =>
              _trigger(context, people, session, open),
        ),
      ),
    );
  }

  Widget _trigger(
    BuildContext context,
    List<CanvasPerson> people,
    CanvasPeopleSession? session,
    bool open,
  ) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final followed = session?.followed;
    final ring = followed == null
        ? null
        : session?.followedColor ?? tokens.accentFill;
    final ordered = _shownFirst(people, followed);
    final shown = ordered.take(_shownInPill).toList();
    final more = people.length - shown.length;
    const size = AppAvatarSize.s20;
    const step = size - AppSpacing.s4;
    return Semantics(
      container: true,
      button: true,
      expanded: open,
      label: followed == null
          ? 'People here, ${people.length}'
          : 'People here, ${people.length}, following '
                '${people.where((p) => p.id == followed).firstOrNull?.name ?? 'someone'}',
      excludeSemantics: true,
      onTap: _toggle,
      child: Tooltip(
        message: 'People here',
        excludeFromSemantics: true,
        child: CanvasPillSurface(
          tokens: tokens,
          onTap: _toggle,
          borderColor: ring,
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
                            child: _avatar(shown[i], size),
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

  Widget _avatar(CanvasPerson person, double size) {
    final participant = person.participant;
    return KeyedSubtree(
      key: ValueKey(person.id),
      child: participant == null
          ? UserAvatar(name: person.name, userId: person.id, size: size)
          : CanvasRosterAvatar(participant: participant, size: size),
    );
  }

  // A barrier under the list, so a click outside closes it without reaching the board or a menu opened from a row.
  Widget _popover() {
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
                    const AppMenuLabel('People here'),
                    CanvasPeopleRows(onDone: _hide),
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
