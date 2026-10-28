// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one list of people on the canvas: who is here, who is talking, a follow toggle each, and the one place to bring everyone to your view.
/// A person in the call also opens the menu their call tile has.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../../widgets/confirm_dialog.dart';
import '../../members/providers/blocks_controller.dart';
import '../../members/widgets/user_avatar.dart';
import '../../voice/providers/voice_flags.dart';
import '../widgets/canvas_participant_menu.dart';
import '../widgets/canvas_roster_avatar.dart';
import 'canvas_follow_targets.dart';
import 'canvas_people_session.dart';

/// One entry of the list: a call participant, or someone who is only on the board.
class CanvasPerson {
  const CanvasPerson({required this.id, required this.name, this.participant});

  final String id;
  final String name;
  final VoiceParticipant? participant;

  bool get isSelf => participant?.isLocal ?? false;
}

/// This device first, then the call with speakers ahead, then people who are only on the board.
List<CanvasPerson> canvasPeople({
  required List<VoiceParticipant> call,
  required List<CanvasFollowTarget> onCanvas,
}) {
  final inCall = [
    ...call.where((p) => p.isLocal),
    ...call.where((p) => !p.isLocal && p.isSpeaking),
    ...call.where((p) => !p.isLocal && !p.isSpeaking),
  ];
  final ids = {for (final p in inCall) p.identity};
  return [
    for (final p in inCall)
      CanvasPerson(id: p.identity, name: p.name, participant: p),
    for (final t in onCanvas)
      if (!ids.contains(t.id)) CanvasPerson(id: t.id, name: t.name),
  ];
}

/// The people in the call that this device's block list leaves visible.
final canvasCallPeopleProvider = Provider<List<VoiceParticipant>>((ref) {
  final blocks = ref.watch(blocksProvider);
  return [
    for (final p in ref.watch(voiceParticipantsProvider))
      if (!blocks.contains(p.identity)) p,
  ];
});

Future<bool> _confirmBringEveryone(BuildContext context) =>
    confirmDangerousAction(
      context,
      title: 'Bring everyone to you?',
      message:
          'Every viewer jumps to the part of the board you are looking at.',
      confirmLabel: 'Bring everyone',
    );

class CanvasPeopleRows extends ConsumerWidget {
  const CanvasPeopleRows({super.key, required this.onDone});

  /// Closes the list that holds these rows, once an action has been taken.
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final session = CanvasPeopleScope.maybeOf(context);
    final people = canvasPeople(
      call: ref.watch(canvasCallPeopleProvider),
      onCanvas: session?.onCanvas ?? const [],
    );
    final others = people.any((p) => !p.isSelf);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (people.isEmpty)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s8),
            child: Text(
              'Nobody else is here.',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ),
        for (final person in people)
          CanvasPersonRow(
            key: ValueKey(person.id),
            person: person,
            session: session,
          ),
        if (session != null && session.canBringEveryone && others) ...[
          const AppMenuDivider(),
          AppListRow(
            label: 'Bring everyone to me',
            leading: const Icon(AppIcons.members, size: AppSizes.icon16),
            onTap: () => unawaited(_bringEveryone(context, session)),
          ),
        ],
      ],
    );
  }

  Future<void> _bringEveryone(
    BuildContext context,
    CanvasPeopleSession session,
  ) async {
    if (!await _confirmBringEveryone(context)) return;
    onDone();
    session.onBringEveryone();
  }
}

/// One person: avatar with the marks a list owes them, state in words, a follow toggle, and the call menu where there is one.
class CanvasPersonRow extends StatelessWidget {
  const CanvasPersonRow({super.key, required this.person, this.session});

  final CanvasPerson person;
  final CanvasPeopleSession? session;

  @override
  Widget build(BuildContext context) {
    final participant = person.participant;
    if (participant == null) return _row(context, null);
    return CanvasParticipantMenu(participant: participant, builder: _row);
  }

  Widget _row(BuildContext context, VoidCallback? open) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final participant = person.participant;
    final session = this.session;
    final followed = session?.followed == person.id;
    // Said in words as well as icons, so a screen reader hears who is muted or talking.
    final state = [
      if (person.isSelf) 'You',
      if (participant?.isSpeaking ?? false) 'Speaking',
      if (participant?.isDeafened ?? false)
        'Deafened'
      else if (participant?.isMuted ?? false)
        'Muted',
      if (followed) 'Following',
    ];
    final canFollow = session != null && !person.isSelf;
    return AppListRow(
      label: person.name,
      meta: state.isEmpty ? null : state.join(', '),
      stateDescription: state.isEmpty ? null : state.join(', ').toLowerCase(),
      leading: FollowRing(
        color: followed ? session?.followedColor ?? tokens.accentFill : null,
        child: participant == null
            ? UserAvatar(
                name: person.name,
                userId: person.id,
                size: AppAvatarSize.s28,
              )
            : CanvasRosterAvatar(participant: participant),
      ),
      trailing: open == null
          ? null
          : Icon(
              AppIcons.moreVertical,
              size: AppSizes.icon16,
              color: tokens.textSecondary,
            ),
      trailingExtra: canFollow
          ? CanvasFollowButton(
              name: person.name,
              following: followed,
              onPressed: () => session.toggleFollow(person.id),
            )
          : null,
      onTap: open ?? (canFollow ? () => session.toggleFollow(person.id) : null),
    );
  }
}

class CanvasFollowButton extends StatelessWidget {
  const CanvasFollowButton({
    super.key,
    required this.name,
    required this.following,
    required this.onPressed,
  });

  final String name;
  final bool following;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => AppIconButton(
    icon: AppIcons.followView,
    active: following,
    semanticLabel: following ? 'Following $name, tap to stop' : 'Follow $name',
    tooltip: following ? 'Stop following $name' : 'Follow $name',
    size: AppIconButtonSize.sm,
    iconSize: AppSizes.icon16,
    onPressed: onPressed,
  );
}

/// An outline in the followed person's colour around their avatar; the space is kept when it is off so a row never shifts.
class FollowRing extends StatelessWidget {
  const FollowRing({super.key, required this.color, required this.child});

  final Color? color;
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    key: color == null ? null : followRingKey,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      border: Border.all(color: color ?? Colors.transparent, width: 2),
    ),
    child: Padding(padding: const EdgeInsets.all(2), child: child),
  );
}

const followRingKey = ValueKey('canvas-follow-ring');
