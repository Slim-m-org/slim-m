// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sheet for making a channel: a name, a text/voice choice, a Lobby
/// toggle for voice (decision 0065), and - for a caller who holds
/// MANAGE_ROLES - a Private toggle, sent through
/// `POST /channels` (`SlimmApi.createChannel`).
///
/// Opened from the Space menu's "Add channel", and from the `+` on a
/// category header in the rail - which passes that category so the sheet
/// starts on the section the person asked from. A category picker lets them
/// change it, so a channel never has to land uncategorised and be dragged.
///
/// The toggle exists to close the window a create-then-restrict two-step
/// otherwise leaves open: every new channel is public by construction (see
/// `EVERYONE_DEFAULTS` in `crates/slimm-server/src/store/bootstrap.rs`), so
/// without it a channel meant to be private is briefly visible to everyone
/// between creation and a follow-up permissions edit. It denies `@everyone`
/// and grants only the creator - no role picker: others are added afterwards
/// through the existing channel-permissions surface.
///
/// Absent, not disabled, for a caller without MANAGE_ROLES: the server
/// refuses that combination outright (see `create`'s own doc in
/// `http/channels.rs`), and a control that can only fail is the thing this
/// codebase keeps taking back out.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import 'package:slimm_api/api.dart' as api;

import '../../../permissions.dart';
import '../../../providers/admin_providers.dart';
import '../../../providers/providers.dart';
import '../../../providers/store_stream.dart';
import '../../../routing/routes.dart';
import '../../../ids.dart';
import '../../../widgets/name_entry_sheet.dart';
import 'channel_settings_rooms_section.dart'
    show lobbyDescription, lobbyLabel, lobbySemanticLabel;
import 'category_choice_row.dart';
import 'private_audience_picker.dart';
import '../../settings/widgets/settings_toggle_row.dart';
import '../providers/channel_actions.dart';

/// Opens the sheet, defaulting the kind picker to [initialKind]: still
/// changeable inside the sheet, since it is only a starting guess, not a
/// hard constraint the server enforces.
///
/// [categoryId] is only where the category picker starts: a `+` on a category
/// passes that one, and the Space menu or the rail's uncategorised `+` pass none.
Future<void> showCreateChannelSheet(
  BuildContext context, {
  required String initialKind,
  String? categoryId,
}) {
  return showAppSheet<void>(
    context,
    builder: (context) =>
        _CreateChannelSheet(initialKind: initialKind, categoryId: categoryId),
  );
}

class _CreateChannelSheet extends ConsumerStatefulWidget {
  const _CreateChannelSheet({required this.initialKind, this.categoryId});

  final String initialKind;
  final String? categoryId;

  @override
  ConsumerState<_CreateChannelSheet> createState() =>
      _CreateChannelSheetState();
}

class _CreateChannelSheetState extends ConsumerState<_CreateChannelSheet> {
  late String _kind = widget.initialKind;
  late String _category = widget.categoryId ?? noCategory;
  final _categories = StoreStream<List<ChannelCategoryRow>>(
    (s) => s.watchCategories(),
  );
  bool _restricted = false;
  bool _lobby = false;
  final Set<String> _audience = {};
  final _createId = newChannelId();

  Future<VoidCallback?> _create(String name) async {
    final created = await ref
        .read(channelActionsProvider)
        .createChannel(
          name: name,
          kind: _kind,
          categoryId: _category == noCategory ? null : _category,
          restricted: _restricted,
          createsRooms: _kind == 'voice' && _lobby,
          id: _createId,
        );
    if (_restricted) await _grantAudience(created.id);
    if (!mounted) return null;
    final router = GoRouter.of(context);
    // Selected, never joined: the voice screen offers Join like any visit to read.
    final route = Routes.channel(created.id, openChat: _kind == 'voice');
    return () => router.go(route);
  }

  /// The channel already exists by now and a retry re-sends the same id, so a failure here leaves it usable and the sheet open to try again.
  Future<void> _grantAudience(String channelId) async {
    if (_audience.isEmpty) return;
    final edits = [
      for (final key in _audience)
        api.ChannelOverwriteEdit(
          kind: key.startsWith('role:')
              ? api.OverwriteTarget.role
              : api.OverwriteTarget.member,
          id: key.substring(key.indexOf(':') + 1),
          allow: Perm.viewChannel,
        ),
    ];
    try {
      await ref.read(channelActionsProvider).setOverwrites(channelId, edits);
    } on api.ApiException catch (e) {
      throw NameEntryPartialFailure(
        'The channel was created, but choosing who can see it failed '
        '(${e.message}). Try again, or set it in the channel settings.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(storeProvider).valueOrNull;
    if (store == null) return _sheet(context, const []);
    return StreamBuilder<List<ChannelCategoryRow>>(
      stream: _categories.of(store),
      builder: (context, snapshot) =>
          _sheet(context, snapshot.data ?? const []),
    );
  }

  Widget _sheet(BuildContext context, List<ChannelCategoryRow> categories) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    // Absent, not disabled, for a caller without MANAGE_ROLES - see this class's own doc.
    final canRestrict = ref
        .watch(myPermissionsProvider)
        .hasPermission(Perm.manageRoles);

    return NameEntrySheet(
      noun: 'channel',
      title: 'Create a channel',
      onCreate: _create,
      extraFields: [
        const SizedBox(height: AppSpacing.s8),
        if (categories.isNotEmpty) ...[
          CategoryChoiceRow(
            categories: categories,
            value: _category,
            onChanged: (id) => setState(() => _category = id),
          ),
          const SizedBox(height: AppSpacing.s8),
        ],
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
        if (_kind == 'voice')
          SettingsToggleRow(
            label: lobbyLabel,
            description: lobbyDescription,
            value: _lobby,
            onChanged: (v) => setState(() => _lobby = v),
            semanticLabel: lobbySemanticLabel,
            inset: 0,
          ),
        if (canRestrict)
          SettingsToggleRow(
            label: 'Private',
            description: 'Only the people you pick can see this channel.',
            value: _restricted,
            onChanged: (v) => setState(() => _restricted = v),
            semanticLabel: 'Make this channel private',
            inset: 0,
          ),
        if (canRestrict && _restricted)
          PrivateAudiencePicker(
            selected: _audience,
            onToggle: (key) => setState(() {
              if (!_audience.remove(key)) _audience.add(key);
            }),
          ),
      ],
    );
  }
}
