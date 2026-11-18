// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One channel's permission overwrites as a grid: a column per principal,
/// a row per permission, each cell tri-state (allow/inherit/deny). Cell taps
/// stay local until Save applies the whole pending set in one batch call;
/// `channel_permissions_grid_rows.dart` is the presentational half.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart' show Channel;
import 'package:slimm_design_system/design_system.dart';

import '../../../../permissions.dart';
import '../../../../providers/admin_providers.dart';
import '../../../../providers/providers.dart' show meProvider;
import '../../../channels/providers/channel_permissions.dart';
import '../../../members/providers/member_presence.dart'
    show channelMembersProvider, membersProvider;
import '../../../../widgets/run_guarded.dart';
import '../save_footer_scope.dart';
import '../settings_save_bar.dart';
import 'category_sync_banner.dart';
import 'channel_permissions_body.dart';
import 'channel_permissions_escalation.dart';
import 'channel_permissions_grid_rows.dart';
import 'channel_permissions_card.dart';
import 'channel_permissions_columns.dart';
import 'channel_permissions_picker.dart';
import 'channel_permissions_rebase.dart';
import '../../providers/settings_actions.dart';
import '../viewport_pin.dart';

class ChannelPermissionsGrid extends ConsumerStatefulWidget {
  const ChannelPermissionsGrid({super.key, required Channel this.channel})
    : categoryId = null;

  /// A category's own overwrites, which its synced channels copy (decision 0064).
  const ChannelPermissionsGrid.forCategory({
    super.key,
    required String this.categoryId,
  }) : channel = null;

  final Channel? channel;
  final String? categoryId;

  @override
  ConsumerState<ChannelPermissionsGrid> createState() =>
      _ChannelPermissionsGridState();
}

class _ChannelPermissionsGridState extends ConsumerState<ChannelPermissionsGrid>
    with GuardedActionState<ChannelPermissionsGrid> {
  final _section = GlobalKey();

  /// `column.key` -> (allow, deny), for every column currently shown -
  /// loaded overwrites plus anything a pending edit or a freshly added
  /// column has touched.
  Map<String, (int, int)> _pending = {};
  Map<String, (int, int)> _original = {};

  /// Columns that existed in [_original] but the caller removed; cleared via
  /// `deleteChannelOverwrite` on save.
  final Set<String> _removed = {};

  bool _saving = false;
  bool _loaded = false;
  final _filter = TextEditingController();

  String? get _categoryId => widget.categoryId;

  AutoDisposeFutureProvider<List<api.ChannelOverwrite>> get _overwrites =>
      switch (_categoryId) {
        final id? => categoryOverwritesProvider(id),
        null => channelOverwritesProvider(widget.channel!.id),
      };

  /// The ceiling on what may be granted: in this channel, or Space-wide.
  int _ceiling(WidgetRef ref) => _categoryId == null
      ? ref.watch(myChannelPermissionsProvider(widget.channel!.id))
      : ref.watch(myPermissionsProvider);

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  void _seedFrom(List<api.ChannelOverwrite> overwrites) {
    if (_loaded) return;
    _loaded = true;
    _original = {
      for (final o in overwrites) '${o.kind.wire}:${o.id}': (o.allow, o.deny),
    };
    _pending = {..._original};
  }

  /// Applies what another admin or the Private switch changed, keeping every
  /// cell, column or removal the local admin has already edited.
  void _mergeRemote(List<api.ChannelOverwrite> overwrites) {
    final fresh = {
      for (final o in overwrites) '${o.kind.wire}:${o.id}': (o.allow, o.deny),
    };
    setState(() {
      mergeRemoteRows(
        original: _original,
        pending: _pending,
        removed: _removed,
        fresh: fresh,
      );
      _original = fresh;
    });
  }

  bool get _isDirty {
    if (_removed.isNotEmpty) return true;
    for (final entry in _pending.entries) {
      if (_original[entry.key] != entry.value) return true;
    }
    return false;
  }

  int get _changeCount {
    var count = _removed.length;
    for (final entry in _pending.entries) {
      if (_original[entry.key] != entry.value) count++;
    }
    return count;
  }

  void _cycle(GridColumn column, int bit, bool grantable) {
    if (_saving) return;
    final (allow, deny) = _pending[column.key] ?? (0, 0);
    final next = switch (CellState.resolve(allow, deny, bit)) {
      CellState.inherit => grantable ? CellState.allow : CellState.deny,
      CellState.allow => CellState.deny,
      CellState.deny => CellState.inherit,
    };
    setState(() {
      var newAllow = allow & ~bit;
      var newDeny = deny & ~bit;
      switch (next) {
        case CellState.allow:
          newAllow |= bit;
        case CellState.deny:
          newDeny |= bit;
        case CellState.inherit:
          break;
      }
      _pending[column.key] = (newAllow, newDeny);
    });
  }

  void _addColumn(GridColumn column) {
    setState(() {
      _pending.putIfAbsent(column.key, () => (0, 0));
      _removed.remove(column.key);
    });
  }

  void _removeColumn(GridColumn column) {
    if (_saving) return;
    setState(() {
      _pending.remove(column.key);
      if (_original.containsKey(column.key)) {
        _removed.add(column.key);
      }
    });
  }

  void _discard() {
    setState(() {
      _pending = {..._original};
      _removed.clear();
    });
  }

  Future<void> _pickTarget() async {
    if (_saving) return;
    final column = await pickGridColumn(
      context,
      taken: {..._pending.keys, ..._reach().outrankedKeys},
    );
    if (column != null && mounted) _addColumn(column);
  }

  /// Clears removals one at a time and forgets each once done, so a later
  /// refusal of the batch cannot make a retry delete the same column twice.
  Future<void> _applyRemovals() async {
    // A category's batch removes a target given an all-zero pair, so removals ride along in _save.
    if (_categoryId != null) return;
    for (final key in _removed.toList()) {
      final (kind, id) = parseOverwriteKey(key);
      try {
        await ref
            .read(settingsActionsProvider)
            .deleteChannelOverwrite(
              channelId: widget.channel!.id,
              kind: kind,
              id: id,
            );
      } on api.NotFoundException catch (error, stack) {
        api.AppLog.swallowed(
          api.LogTag.ui,
          'The permission override was already removed',
          error,
          stack,
        );
      }
      _removed.remove(key);
      _original.remove(key);
    }
  }

  OverwriteReach _reach() => OverwriteReach(
    ladder: ref.read(roleLadderProvider),
    selfId: ref.read(meProvider).valueOrNull?.id,
    roles: ref.read(rolesProvider).valueOrNull ?? const [],
    members: ref.read(membersProvider).valueOrNull ?? const [],
  );

  Future<void> _save() async {
    // Checked before any removal is sent: the server refuses the whole batch for one of these.
    final outranked = _reach().outrankedLabels({
      ..._removed,
      for (final e in _pending.entries)
        if (_original[e.key] != e.value) e.key,
    });
    if (outranked.isNotEmpty) {
      setActionError(outrankedMessage(outranked));
      return;
    }
    final blocked = pendingEscalation(
      original: _original,
      pending: _pending,
      removed: _removed,
      myPermissions: _categoryId == null
          ? ref.read(myChannelPermissionsProvider(widget.channel!.id))
          : ref.read(myPermissionsProvider),
    );
    if (blocked != 0) {
      setActionError(escalationMessage(blocked));
      return;
    }
    setState(() => _saving = true);
    final ok = await guard(
      whatFailed: 'save the permissions grid',
      action: () async {
        await _applyRemovals();
        final edits = <api.ChannelOverwriteEdit>[
          for (final entry in _pending.entries)
            if (_original[entry.key] != entry.value)
              api.ChannelOverwriteEdit(
                kind: parseOverwriteKey(entry.key).$1,
                id: parseOverwriteKey(entry.key).$2,
                allow: entry.value.$1,
                deny: entry.value.$2,
              ),
        ];
        final categoryId = _categoryId;
        if (categoryId != null) {
          await ref
              .read(settingsActionsProvider)
              .batchSetCategoryOverwrites(
                categoryId: categoryId,
                overwrites: [
                  ...edits,
                  for (final key in _removed)
                    api.ChannelOverwriteEdit(
                      kind: parseOverwriteKey(key).$1,
                      id: parseOverwriteKey(key).$2,
                    ),
                ],
              );
          // A sub-category's own save stops it following its parent.
          if (ref.exists(categoryOverwritesSyncedProvider(categoryId))) {
            ref.invalidate(categoryOverwritesSyncedProvider(categoryId));
          }
        } else if (edits.isNotEmpty) {
          await ref
              .read(settingsActionsProvider)
              .batchSetChannelOverwrites(
                channelId: widget.channel!.id,
                overwrites: edits,
              );
        }
      },
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) await _reloadSaved();
  }

  /// Reseeds from the server's answer rather than the provider's previous
  /// value, which an invalidate would hand straight back and pin as saved.
  Future<void> _reloadSaved() async {
    final provider = _overwrites;
    // A saved overwrite can grant or revoke view, which changes who the channel's member list holds.
    if (widget.channel case final channel?) {
      ref.invalidate(channelMembersProvider(channel.id));
      ref.invalidate(channelOverwritesSyncedProvider(channel.id));
    }
    try {
      final fresh = await ref.refresh(provider.future);
      if (!mounted) return;
      setState(() {
        _loaded = false;
        _removed.clear();
        _seedFrom(fresh);
      });
    } on api.ApiException catch (error, stack) {
      api.reportFailure(
        api.LogTag.ui,
        'reload the saved channel permissions',
        error,
        stack,
      );
      if (mounted) setActionError('Saved, but could not reload the grid.');
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(_overwrites, (previous, next) {
      if (!_loaded || !next.hasValue || next.isLoading) return;
      if (identical(previous?.value, next.value)) return;
      _mergeRemote(next.requireValue);
    });
    final overwritesAsync = ref.watch(_overwrites);
    final rolesAsync = ref.watch(rolesProvider);
    final membersAsync = ref.watch(membersProvider);
    final myPermissions = _ceiling(ref);
    ref
      ..watch(roleLadderProvider)
      ..watch(meProvider);

    if (!overwritesAsync.hasValue ||
        !rolesAsync.hasValue ||
        !membersAsync.hasValue) {
      return _loadFailure(overwritesAsync, rolesAsync, membersAsync) ??
          const Center(child: AppSpinner(size: AppSpinnerSize.lg));
    }

    _seedFrom(overwritesAsync.requireValue);
    final columns = _columns(
      rolesAsync.requireValue,
      membersAsync.requireValue,
    );

    // Unbounded height means a scrolling pane hosts us: lay out at full height so that pane is the only vertical scroller.
    return LayoutBuilder(
      builder: (context, outer) => _buildGrid(
        columns,
        myPermissions,
        shrinkWrap: !outer.hasBoundedHeight,
      ),
    );
  }

  Widget? _loadFailure(
    AsyncValue<Object?> overwrites,
    AsyncValue<Object?> roles,
    AsyncValue<Object?> members,
  ) {
    if (overwrites.hasError) {
      return AppErrorState(
        message: _categoryId == null
            ? "Could not load this channel's overwrites."
            : "Could not load this category's overwrites.",
        onRetry: () => ref.invalidate(_overwrites),
      );
    }
    if (roles.hasError) {
      return AppErrorState(
        message: 'Could not load roles.',
        onRetry: () => ref.invalidate(rolesProvider),
      );
    }
    if (members.hasError) {
      return AppErrorState(
        message: 'Could not load members.',
        onRetry: () => ref.invalidate(membersProvider),
      );
    }
    return null;
  }

  List<GridColumn> _columns(
    List<api.Role> roles,
    List<api.UserProfile> members,
  ) {
    final everyone = roles.where((r) => r.isEveryone).firstOrNull;
    final reach = _reach();
    return [
          if (everyone != null)
            GridColumn(
              kind: api.OverwriteTarget.role,
              id: everyone.id,
              label: everyone.name,
              isBot: false,
              isEveryone: true,
            ),
          for (final key in _pending.keys)
            if (everyone == null || key != 'role:${everyone.id}')
              if (resolveGridColumn(key, roles, members) case final column?)
                column,
        ]
        .map(
          (c) => gridColumnWithCounts(
            c,
            _pending[c.key] ?? (0, 0),
            locked: !reach.reaches(c.key),
          ),
        )
        .toList();
  }

  Widget _buildGrid(
    List<GridColumn> columns,
    int myPermissions, {
    required bool shrinkWrap,
  }) {
    final view = PermissionGridView(
      shrinkWrap: shrinkWrap,
      columns: columns,
      filter: _filter.text,
      onAdd: _pickTarget,
      onRemove: _removeColumn,
      cellBuilder: (column, spec) => _cell(column, spec, myPermissions),
    );
    final card = PermissionsCard(
      filter: _filter,
      onFilterChanged: () => setState(() {}),
      onAdd: _pickTarget,
      shrinkWrap: shrinkWrap,
      grid: view,
    );
    return Column(
      key: _section,
      mainAxisSize: shrinkWrap ? MainAxisSize.min : MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.channel case final channel? when channel.categoryId != null)
          CategorySyncBanner(channelId: channel.id),
        if (actionError case final error?)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.s12),
            child: AppErrorState(message: error, onDismiss: clearActionError),
          ),
        if (shrinkWrap) card else Expanded(child: card),
        SaveFooterSlot(
          save: _isDirty
              ? (
                  changeCount: _changeCount,
                  saving: _saving,
                  onDiscard: _discard,
                  onSave: _save,
                )
              : null,
          inline: (_) => _saveBar(shrinkWrap: shrinkWrap),
        ),
      ],
    );
  }

  /// In a page that scrolls, the bar holds to the bottom of the view while the grid is on screen, so an edit far down never hides it.
  Widget _saveBar({required bool shrinkWrap}) {
    final bar = Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s12),
      child: SettingsSaveBar(
        changeCount: _changeCount,
        saving: _saving,
        onDiscard: _discard,
        onSave: _save,
      ),
    );
    return shrinkWrap
        ? ViewportPin(edge: ViewportEdge.bottom, section: _section, child: bar)
        : bar;
  }

  Widget _cell(GridColumn column, PermSpec spec, int myPermissions) {
    final grantable = myPermissions.hasPermission(spec.bit);
    final (allow, deny) = _pending[column.key] ?? (0, 0);
    final (origAllow, origDeny) = _original[column.key] ?? (0, 0);
    final state = CellState.resolve(allow, deny, spec.bit);
    return Cell(
      key: ValueKey('cell:${column.key}:${spec.bit}'),
      state: state,
      changed: state != CellState.resolve(origAllow, origDeny, spec.bit),
      disabled: !grantable || _saving || column.locked,
      label: '${spec.label}, ${column.label}',
      tooltip: '${spec.label} for ${column.label}',
      onTap: () => _cycle(column, spec.bit, grantable),
    );
  }
}
