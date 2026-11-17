// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "How others see you": the profile card's own banner, header, about and
/// roles, drawn for you as anyone else would see them.
///
/// Name, handle, colour and join date come from [meProvider] and the unsaved
/// pronouns and about text from [profileDraftProvider], so it follows edits as
/// they are typed. Only the roles need [userProfileProvider]: `Me` carries none.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../members/providers/profile_draft.dart';
import '../../../providers/providers.dart';
import '../../members/providers/user_profiles.dart';
import '../../members/widgets/member_profile_identity.dart';
import '../../members/widgets/member_profile_roles.dart';
import '../../members/widgets/member_profile_sections.dart';
import '../../members/widgets/profile_banner.dart';
import 'settings_section_header.dart';

class SettingsProfilePreview extends ConsumerWidget {
  const SettingsProfilePreview({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final me = ref.watch(meProvider).valueOrNull;
    if (me == null) return const SizedBox.shrink();
    final draft = ref.watch(profileDraftProvider);
    final held = ref.watch(userProfileProvider(me.id)).valueOrNull;
    final pronouns = (draft.pronouns ?? me.pronouns ?? '').trim();
    final about = (draft.about ?? me.about ?? '').trim();
    final profile = api.UserProfile(
      id: me.id,
      username: me.username,
      displayName: me.displayName,
      createdAt: me.createdAt,
      avatarUpdatedAt: me.avatarUpdatedAt,
      bannerUpdatedAt: me.bannerUpdatedAt,
      roles: held?.roles ?? const [],
      roleIds: held?.roleIds ?? const [],
      roleColors: held?.roleColors ?? const [],
      statusText: me.statusText,
      pronouns: pronouns.isEmpty ? null : pronouns,
      about: about,
      profileColor: me.profileColor,
      profileColorRgb: me.profileColorRgb,
    );

    return SettingsSectionCard(
      title: 'How others see you',
      topGap: kDenseSectionTopGap,
      description: 'Updates as you edit below.',
      children: [
        ColoredBox(
          color: tokens.surfaceRaised,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              MemberProfileBanner(profile: profile),
              MemberProfileHeader(
                profile: profile,
                isSelf: false,
                inCallTogether: false,
              ),
              if (about.isNotEmpty) MemberProfileAbout(about: about),
              MemberProfileRoles(profile: profile),
            ],
          ),
        ),
      ],
    );
  }
}
