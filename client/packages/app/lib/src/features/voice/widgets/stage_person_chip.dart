// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The compact chip an audio-only person shrinks to when the stage has no room
/// for avatar tiles, and the "+N" chip that stands for the people past the end.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../members/widgets/user_avatar.dart';

class StagePersonChip extends StatelessWidget {
  const StagePersonChip({super.key, required this.participant, this.onTap})
    : overflowCount = null;

  const StagePersonChip.overflow({super.key, required int count})
    : participant = null,
      onTap = null,
      overflowCount = count;

  final VoiceParticipant? participant;
  final int? overflowCount;
  final void Function(BuildContext anchor)? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final person = participant;
    final label = person?.name ?? '+$overflowCount';
    return Semantics(
      container: true,
      button: onTap != null,
      label: person == null ? '$overflowCount more in the call' : person.name,
      onTap: onTap == null ? null : () => onTap!(context),
      child: ExcludeSemantics(
        child: GestureDetector(
          onTap: onTap == null ? null : () => onTap!(context),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: tokens.surfaceRaised,
              borderRadius: BorderRadius.circular(AppRadii.full),
              border: Border.all(color: tokens.borderSubtle),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
              child: Row(
                mainAxisAlignment: person == null
                    ? MainAxisAlignment.center
                    : MainAxisAlignment.start,
                children: [
                  if (person != null) ...[
                    UserAvatar(
                      name: person.name,
                      userId: person.identity,
                      size: AppAvatarSize.s20,
                    ),
                    const SizedBox(width: AppSpacing.s8),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption.copyWith(
                        color: tokens.textPrimary,
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
