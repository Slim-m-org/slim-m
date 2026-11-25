// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sheet for making a channel: a name, a text/voice/canvas choice, a
/// Lobby and a Canvas toggle for voice (decision 0065), a Voice call toggle
/// for canvas, and - for a caller who holds
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
import '../providers/canvas_channels_supported.dart';
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

const _kindLabels = {'text': 'Text', 'voice': 'Voice', 'canvas': 'Canvas'};

const _kindCaptions = {
  'text': 'People post messages, images and files to read at their own pace.',
  'voice': 'People join a live call to talk, share video and their screen.',
  'canvas': 'A shared board to work on together, with chat to the side.',
};

class _CreateChannelSheet extends ConsumerStatefulWidget {
  const _CreateChannelSheet({required this.initialKind, this.categoryId});

  final String initialKind;
  final String? categoryId;

  @override
  ConsumerState<_CreateChannelSheet> createState() =>
      _CreateChannelSheetState();
}

class _CreateChannelSheetState extends ConsumerState<_CreateChannelSheet> {
  late String _picked = widget.initialKind;
  late String _category = widget.categoryId ?? noCategory;

  /// Categories this account may not file under, as the last listing said.
  Set<String> _shut = const {};

  /// [_category], or none when it names one this account may not file under.
  String get _chosen => _shut.contains(_category) ? noCategory : _category;
  final _categories = StoreStream<List<ChannelCategoryRow>>(
    (s) => s.watchCategories(),
  );
  bool _restricted = false;
  bool _lobby = false;
  bool _canvas = false;
  bool _call = false;
  final Set<String> _audience = {};
  final _createId = newChannelId();

  /// A kind this server does not know falls back to text.
  String get _kind => _picked == 'canvas' && !_canvasKinds ? 'text' : _picked;

  bool get _canvasKinds => ref.read(canvasChannelsSupportedProvider);

  void _pickKind(String kind) => setState(() {
    _picked = kind;
    _lobby = false;
    _canvas = false;
    _call = false;
  });

  Future<VoidCallback?> _create(String name) async {
    if (_picked == 'canvas' && !_canvasKinds) {
      throw const NameEntryPartialFailure(
        "This server doesn't support canvas channels.",
      );
    }
    final created = await ref
        .read(channelActionsProvider)
        .createChannel(
          name: name,
          kind: _kind,
          categoryId: _chosen == noCategory ? null : _chosen,
          restricted: _restricted,
          createsRooms: _kind == 'voice' && _lobby,
          canvasEnabled: _kind == 'voice' && _canvasKinds ? _canvas : null,
          voiceEnabled: _kind == 'canvas' ? _call : null,
          id: _createId,
        );
    if (_restricted) await _grantAudience(created.id);
    // A new voice channel stays a row in the rail: opening it showed an empty call nobody asked to see.
    if (!mounted || _kind == 'voice') return null;
    final router = GoRouter.of(context);
    final route = Routes.channel(created.id);
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

  Widget _sheet(BuildContext context, List<ChannelCategoryRow> all) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    _shut = {
      for (final c in all)
        if (!c.canFile) c.id,
    };
    final categories = [
      for (final c in all)
        if (c.canFile) c,
    ];
    // Absent, not disabled, for a caller without MANAGE_ROLES - see this class's own doc.
    final canRestrict = ref
        .watch(myPermissionsProvider)
        .hasPermission(Perm.manageRoles);

    final canvasKinds = ref.watch(canvasChannelsSupportedProvider);
    final kinds = ['text', 'voice', if (canvasKinds) 'canvas'];

    return NameEntrySheet(
      noun: 'channel',
      title: 'Create a channel',
      onCreate: _create,
      extraFields: [
        const SizedBox(height: AppSpacing.s8),
        if (categories.isNotEmpty) ...[
          CategoryChoiceRow(
            categories: categories,
            value: _chosen,
            onChanged: (id) => setState(() => _category = id),
          ),
          const SizedBox(height: AppSpacing.s8),
        ],
        AppSegmentedControl.inline(
          semanticLabel: 'Channel kind',
          options: [
            for (final kind in kinds)
              AppSegmentedOption(label: _kindLabels[kind]!),
          ],
          selectedIndex: kinds.indexOf(_kind),
          onSegmentSelected: (i) => _pickKind(kinds[i]),
        ),
        const SizedBox(height: AppSpacing.s4),
        Text(
          _kindCaptions[_kind]!,
          style: AppText.caption.copyWith(color: tokens.textSecondary),
        ),
        const SizedBox(height: AppSpacing.s8),
        if (_kind == 'voice') ...[
          SettingsToggleRow(
            label: lobbyLabel,
            description: lobbyDescription,
            value: _lobby,
            onChanged: (v) => setState(() => _lobby = v),
            semanticLabel: lobbySemanticLabel,
            inset: 0,
          ),
          if (canvasKinds)
            SettingsToggleRow(
              label: 'Canvas',
              description: 'Adds a shared board to this channel.',
              value: _canvas,
              onChanged: (v) => setState(() => _canvas = v),
              semanticLabel: 'Add a canvas to this channel',
              inset: 0,
            ),
        ],
        if (_kind == 'canvas')
          SettingsToggleRow(
            label: 'Voice call',
            description: 'Lets people talk while they work.',
            value: _call,
            onChanged: (v) => setState(() => _call = v),
            semanticLabel: 'Let people call in this channel',
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
