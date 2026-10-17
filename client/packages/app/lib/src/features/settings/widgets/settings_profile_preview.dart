// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "How others see you": a live preview card with the banner in the profile
/// colour, the avatar, name, handle, about line and role badges.
///
/// Name, handle, colour and join date come from [meProvider] and the unsaved
/// pronouns and about text from [profileDraftProvider], so it follows edits as
/// they are typed. Only the role chips need [userProfileProvider]: `Me`
/// carries no roles.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../members/providers/profile_draft.dart';
import '../../../providers/providers.dart';
import '../../members/providers/user_profiles.dart';
import '../../members/widgets/member_profile_identity.dart';
import 'settings_section_header.dart';
import '../../members/widgets/user_avatar.dart';

const double _bannerHeight = 56;
const double _avatarSize = AppAvatarSize.s72;
const double _avatarRing = 4;
const double _overlap = 36;

class SettingsProfilePreview extends ConsumerWidget {
  const SettingsProfilePreview({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final me = ref.watch(meProvider).valueOrNull;
    if (me == null) return const SizedBox.shrink();
    final draft = ref.watch(profileDraftProvider);
    final roles =
        ref.watch(userProfileProvider(me.id)).valueOrNull?.roles ?? const [];
    final pronouns = (draft.pronouns ?? me.pronouns ?? '').trim();
    final about = (draft.about ?? me.about ?? '').trim();
    final colour = me.profileColor;
    final banner = colour == null
        ? tokens.surfaceSunken
        : AppCanvasColors.cursors[colour % AppCanvasColors.cursors.length];

    return SettingsSectionCard(
      title: 'How others see you',
      description: 'Updates as you edit below.',
      children: [
        ColoredBox(
          color: tokens.surfaceBase,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                key: const Key('profile-preview-banner'),
                height: _bannerHeight,
                color: banner,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 10,
                  children: [
                    _AvatarAndJoined(
                      userId: me.id,
                      name: me.displayName,
                      createdAt: me.createdAt,
                      ring: tokens.surfaceBase,
                    ),
                    _Details(
                      name: me.displayName,
                      username: me.username,
                      pronouns: pronouns,
                      about: about,
                      roles: roles,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The avatar rises [_overlap] into the banner; the join date stays on the
/// avatar's baseline at the right.
class _AvatarAndJoined extends StatelessWidget {
  const _AvatarAndJoined({
    required this.userId,
    required this.name,
    required this.createdAt,
    required this.ring,
  });

  final String userId;
  final String name;
  final int createdAt;
  final Color ring;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    const full = _avatarSize + 2 * _avatarRing;
    return SizedBox(
      height: full - _overlap,
      child: OverflowBox(
        alignment: Alignment.bottomCenter,
        minHeight: 0,
        maxHeight: full,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: ring, width: _avatarRing),
              ),
              child: ExcludeSemantics(
                child: UserAvatar(
                  userId: userId,
                  name: name,
                  size: _avatarSize,
                  presence: true,
                ),
              ),
            ),
            const Spacer(),
            Text(
              formatJoinDate(createdAt),
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _Details extends StatelessWidget {
  const _Details({
    required this.name,
    required this.username,
    required this.pronouns,
    required this.about,
    required this.roles,
  });

  final String name;
  final String username;
  final String pronouns;
  final String about;
  final List<String> roles;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 10,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 2,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              spacing: AppSpacing.s8,
              children: [
                Flexible(
                  child: Text(
                    name,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.heading.copyWith(
                      color: tokens.textPrimary,
                      fontWeight: AppWeights.semi,
                    ),
                  ),
                ),
                const AppBadge(variant: AppBadgeVariant.tag, label: 'You'),
              ],
            ),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '@$username',
                    style: AppText.code.copyWith(
                      fontSize: AppText.caption.fontSize,
                    ),
                  ),
                  if (pronouns.isNotEmpty) TextSpan(text: ' · $pronouns'),
                ],
              ),
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ],
        ),
        if (about.isNotEmpty)
          Text(about, style: AppText.ui.copyWith(color: tokens.textPrimary)),
        if (roles.isNotEmpty)
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final role in roles)
                AppBadge(variant: AppBadgeVariant.tag, label: role),
            ],
          ),
      ],
    );
  }
}
