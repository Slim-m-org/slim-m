// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The top of a category's permissions sheet: a Private category switch,
/// who can see it, and what a save here does not reach (decision 0125).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

import '../../../permissions.dart';
import '../../../providers/admin_providers.dart';
import '../../../providers/providers.dart' show sessionProvider;
import '../../../widgets/confirm_dialog.dart';
import '../../members/providers/member_presence.dart' show membersProvider;
import '../../../widgets/run_guarded.dart';
import '../../settings/widgets/settings_save_feedback.dart';
import '../../settings/widgets/settings_section_header.dart';
import '../../settings/widgets/settings_toggle_row.dart';
import '../providers/view_access.dart';
import 'category_unsynced_notice.dart';
import 'who_can_see.dart';

class CategoryPrivateSection extends ConsumerStatefulWidget {
  const CategoryPrivateSection({
    super.key,
    required this.categoryId,
    required this.name,
    this.subCategories = const [],
    this.channels = const [],
    this.leading = const [],
    this.trailing = const [],
    this.followsParent = false,
  });

  final String categoryId;
  final String name;

  /// Rows the card opens and closes with, around its own.
  final List<Widget> leading;
  final List<Widget> trailing;

  /// A sub-category following its parent takes its access from there, so it only lists who sees it.
  final bool followsParent;
  final List<ChannelCategoryRow> subCategories;
  final List<Channel> channels;

  @override
  ConsumerState<CategoryPrivateSection> createState() =>
      _CategoryPrivateSectionState();
}

class _CategoryPrivateSectionState extends ConsumerState<CategoryPrivateSection>
    with GuardedActionState<CategoryPrivateSection> {
  bool? _optimistic;
  bool _saving = false;

  CategoryViewTarget get _target => CategoryViewTarget(widget.categoryId);

  Future<void> _set(bool private) async {
    if (private &&
        !await confirmDangerousAction(
          context,
          title: 'Make ${widget.name} private?',
          message:
              'Only administrators and anyone you add will see the '
              'channels that follow it.',
          confirmLabel: 'Make private',
        )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _saving = true;
      _optimistic = private;
    });
    final target = _target;
    final ok = await guard(
      whatFailed: private ? 'make the category private' : 'make it public',
      action: () async {
        final existing = await ref.read(target.overwrites.future);
        final roles = await ref.read(rolesProvider.future);
        final everyone = roles.firstWhere((r) => r.isEveryone);
        final selfId = await _selfRowId(existing, everyoneRoleId: everyone.id);
        await ref
            .read(viewAccessWriterProvider)
            .write(
              target,
              private
                  ? privateEdits(
                      existing,
                      everyoneRoleId: everyone.id,
                      selfId: selfId,
                    )
                  : publicEdits(
                      existing,
                      everyoneRoleId: everyone.id,
                      selfId: selfId,
                    ),
            );
        target.affected.forEach(ref.invalidate);
      },
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (!ok) _optimistic = null;
    });
  }

  /// The caller whose own Allow View row the switch writes and lifts, or null
  /// when an administrator or a role of theirs keeps them in without one.
  /// Who the switch gives an Allow View row, or null when Administrator or
  /// one of their roles keeps them in.
  Future<String?> _selfRowId(
    List<api.ChannelOverwrite> existing, {
    required String everyoneRoleId,
  }) async {
    if (ref.read(myPermissionsProvider).hasPermission(Perm.administrator)) {
      return null;
    }
    final selfId = ref.read(sessionProvider).tokens?.userId;
    final members = await ref.read(membersProvider.future);
    final self = members.where((m) => m.id == selfId).firstOrNull;
    final throughRole = viewAllowedToARole(
      existing,
      everyoneRoleId: everyoneRoleId,
      roleIds: self?.roleIds ?? const [],
    );
    return throughRole ? null : selfId;
  }

  bool? _stored() {
    final overwrites = ref.watch(_target.overwrites).valueOrNull;
    final everyone = ref
        .watch(rolesProvider)
        .valueOrNull
        ?.where((r) => r.isEveryone)
        .firstOrNull;
    if (overwrites == null || everyone == null) return null;
    return ViewAccess.of(overwrites, everyoneRoleId: everyone.id).private;
  }

  @override
  Widget build(BuildContext context) {
    final stored = _stored();
    // The tapped value stands until a reload agrees with it.
    if (_optimistic != null && !_saving && stored == _optimistic) {
      _optimistic = null;
    }
    final private = _optimistic ?? stored ?? false;
    final error = actionError;
    if (widget.followsParent) {
      return SettingsSectionCard(
        topGap: 0,
        children: [
          ...widget.leading,
          WhoCanSee(target: _target, readOnly: true),
          ...widget.trailing,
        ],
      );
    }
    return SettingsSectionCard(
      topGap: 0,
      children: [
        ...widget.leading,
        SettingsToggleRow(
          label: 'Private category',
          description: 'Only administrators and people you add can see it.',
          value: private,
          semanticLabel: 'Private category',
          onChanged: _saving || stored == null
              ? null
              : (value) => unawaited(_set(value)),
        ),
        if (error != null)
          SettingsSaveFeedback(
            inCard: true,
            tick: 0,
            error: error,
            onDismissError: clearActionError,
          ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            WhoCanSee(target: _target, private: _optimistic),
            CategoryUnsyncedNotice(
              categoryId: widget.categoryId,
              categoryName: widget.name,
              subCategories: widget.subCategories,
              channels: widget.channels,
            ),
          ],
        ),
        ...widget.trailing,
      ],
    );
  }
}
