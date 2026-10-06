// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Remove from #channel" on the member card: a member overwrite denying the
/// channel, written through the same batch route the permissions grid saves
/// with, so the grid shows the new column and can undo it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../permissions.dart';
import '../providers/admin_providers.dart' show rolesProvider;
import '../providers/channel_by_id_provider.dart';
import '../providers/channel_permissions.dart';
import '../providers/member_presence.dart' show channelMembersProvider;
import '../providers/providers.dart';
import 'confirm_dialog.dart';
import 'run_guarded.dart';

/// Whether the viewer may write overwrites in [channelId], the grid's own gate.
bool canRemoveFromChannel(WidgetRef ref, String channelId) => ref
    .watch(myChannelPermissionsProvider(channelId))
    .hasPermission(Perm.manageRoles);

/// Whether [profile]'s roles carry administrator, which no overwrite can deny.
bool memberIsAdministrator(api.UserProfile profile, List<api.Role>? roles) =>
    roles?.any(
      (r) =>
          profile.roleIds.contains(r.id) &&
          r.permissions.hasPermission(Perm.administrator),
    ) ??
    false;

/// Denies [memberId] the channel, keeping whatever else their overwrite says.
Future<void> denyMemberChannel(
  api.SlimmApi client, {
  required String channelId,
  required String memberId,
  required bool isVoice,
}) async {
  final existing = (await client.getChannelOverwrites(channelId))
      .where((o) => o.kind == api.OverwriteTarget.member && o.id == memberId)
      .firstOrNull;
  final denied = Perm.viewChannel | (isVoice ? Perm.connect : 0);
  await client.batchSetChannelOverwrites(
    channelId: channelId,
    overwrites: [
      api.ChannelOverwriteEdit(
        kind: api.OverwriteTarget.member,
        id: memberId,
        allow: (existing?.allow ?? 0) & ~denied,
        deny: (existing?.deny ?? 0) | denied,
      ),
    ],
  );
}

/// The menu row; absent unless [channelId] is a channel the viewer manages.
class MemberRemoveFromChannelItem extends ConsumerWidget {
  const MemberRemoveFromChannelItem({
    super.key,
    required this.channelId,
    required this.profile,
    required this.host,
    required this.guard,
    required this.onDone,
  });

  final String channelId;
  final api.UserProfile profile;
  final BuildContext host;
  final Guard guard;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channel = ref.watch(channelByIdProvider(channelId)).valueOrNull;
    final roles = ref.watch(rolesProvider).valueOrNull;
    if (channel == null ||
        !canRemoveFromChannel(ref, channelId) ||
        memberIsAdministrator(profile, roles)) {
      return const SizedBox.shrink();
    }
    final name = profile.displayName;
    return AppMenuItem(
      label: 'Remove from #${channel.name}',
      leading: AppIcons.revoke,
      tone: AppMenuItemTone.danger,
      onTap: () async {
        final container = ProviderScope.containerOf(context, listen: false);
        final confirmed = await confirmDangerousAction(
          host,
          title: 'Remove $name from #${channel.name}?',
          message:
              'They lose access to this channel right away and it drops out '
              'of their list. They stay in the Space. You can let them back '
              'in from the channel permissions.',
          confirmLabel: 'Remove',
        );
        if (!confirmed) return;
        final client = ref.read(apiProvider);
        final ok = await guard(
          whatFailed: 'remove $name from #${channel.name}',
          action: () => denyMemberChannel(
            client,
            channelId: channelId,
            memberId: profile.id,
            isVoice: channel.kind == 'voice',
          ),
        );
        if (!ok) return;
        container.invalidate(channelMembersProvider(channelId));
        onDone();
      },
    );
  }
}
