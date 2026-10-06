// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sheet for making a channel: a name, a text/voice choice, and - for a
/// caller who holds MANAGE_ROLES - a Private toggle, sent through
/// `POST /channels` (`SlimmApi.createChannel`).
///
/// Opened from the Space menu's "Add channel", and from the `+` on a
/// category header in the rail - which passes that category so the channel
/// lands in the section the person asked from, rather than appearing
/// uncategorised and needing a drag straight afterwards.
///
/// The toggle exists to close the window a create-then-restrict two-step
/// otherwise leaves open: every new channel is public by construction (see
/// `EVERYONE_DEFAULTS` in `crates/slimm-server/src/store/bootstrap.rs`), so
/// without it a channel meant to be private is briefly visible to everyone
/// between creation and a follow-up permissions edit. It denies `@everyone`
/// and grants only the creator - no role picker, for the same reason
/// [categoryId] is not one either: others are added afterwards through the
/// existing channel-permissions surface.
///
/// Absent, not disabled, for a caller without MANAGE_ROLES: the server
/// refuses that combination outright (see `create`'s own doc in
/// `http/channels.rs`), and a control that can only fail is the thing this
/// codebase keeps taking back out.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';

import '../permissions.dart';
import '../providers/admin_providers.dart';
import '../providers/providers.dart';
import '../routing/routes.dart';
import 'name_entry_sheet.dart';
import 'settings_toggle_row.dart';

/// Opens the sheet, defaulting the kind picker to [initialKind]: still
/// changeable inside the sheet, since it is only a starting guess, not a
/// hard constraint the server enforces.
///
/// [categoryId] is not offered as a field, unlike [initialKind]. It is
/// decided by where the sheet was opened from and is not second-guessed
/// here: someone who pressed `+` on a category has already said which one,
/// and someone who used the Space menu named no category at all. Moving a
/// channel afterwards is a drag in the rail, which is a better answer than
/// a picker duplicating it. [categoryName] is display-only, for the sheet to
/// say which category that is; a caller with no category to imply (the
/// Space menu, or the rail's uncategorised `+`) leaves it null and the sheet
/// says nothing about one.
Future<void> showCreateChannelSheet(
  BuildContext context, {
  required String initialKind,
  String? categoryId,
  String? categoryName,
}) {
  return showAppSheet<void>(
    context,
    builder: (context) => _CreateChannelSheet(
      initialKind: initialKind,
      categoryId: categoryId,
      categoryName: categoryName,
    ),
  );
}

class _CreateChannelSheet extends ConsumerStatefulWidget {
  const _CreateChannelSheet({
    required this.initialKind,
    this.categoryId,
    this.categoryName,
  });

  final String initialKind;
  final String? categoryId;
  final String? categoryName;

  @override
  ConsumerState<_CreateChannelSheet> createState() =>
      _CreateChannelSheetState();
}

class _CreateChannelSheetState extends ConsumerState<_CreateChannelSheet> {
  late String _kind = widget.initialKind;
  bool _restricted = false;
  bool _joinMuted = false;

  Future<VoidCallback?> _create(String name) async {
    final created = await ref
        .read(apiProvider)
        .createChannel(
          name: name,
          kind: _kind,
          categoryId: widget.categoryId,
          restricted: _restricted,
          joinMuted: _kind == 'voice' && _joinMuted,
        );
    final store = await ref.read(storeProvider.future);
    await store.upsertChannels([created]);
    if (!mounted) return null;
    final router = GoRouter.of(context);
    return () => router.go(Routes.channel(created.id));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    // Absent, not disabled, for a caller without MANAGE_ROLES - see this class's own doc.
    final canRestrict = ref
        .watch(myPermissionsProvider)
        .hasPermission(Perm.manageRoles);

    return NameEntrySheet(
      noun: 'channel',
      title: 'Create a channel',
      subtitle: widget.categoryName == null
          ? null
          : 'Adding to ${widget.categoryName}',
      onCreate: _create,
      extraFields: [
        const SizedBox(height: AppSpacing.s8),
        AppSegmentedControl.inline(
          semanticLabel: 'Channel kind',
          options: const [
            AppSegmentedOption(label: 'Text'),
            AppSegmentedOption(label: 'Voice'),
          ],
          selectedIndex: _kind == 'voice' ? 1 : 0,
          onSegmentSelected: (i) =>
              setState(() => _kind = i == 1 ? 'voice' : 'text'),
        ),
        const SizedBox(height: AppSpacing.s4),
        Text(
          _kind == 'voice'
              ? 'People join a live call to talk, share video and their screen.'
              : 'People post messages, images and files to read at their own pace.',
          style: AppText.caption.copyWith(color: tokens.textSecondary),
        ),
        const SizedBox(height: AppSpacing.s8),
        if (canRestrict)
          SettingsToggleRow(
            label: 'Private',
            description: 'Only you can see this channel until you add others.',
            value: _restricted,
            onChanged: (v) => setState(() => _restricted = v),
            semanticLabel: 'Make this channel private',
          ),
        if (_kind == 'voice')
          SettingsToggleRow(
            label: 'Join muted',
            description: 'Members start with their mic off and can unmute.',
            value: _joinMuted,
            onChanged: (v) => setState(() => _joinMuted = v),
            semanticLabel: 'Members join this channel muted',
          ),
      ],
    );
  }
}
