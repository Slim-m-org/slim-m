// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A sub-category's first row: whether it follows its parent category's
/// permissions (decision 0120), as a switch that syncs it back or lets it
/// keep its own.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/admin_providers.dart';
import '../../../widgets/confirm_dialog.dart';
import '../../../widgets/run_guarded.dart';
import '../../settings/providers/settings_actions.dart';
import '../../settings/widgets/settings_save_feedback.dart';
import '../../settings/widgets/settings_toggle_row.dart';

class SubCategoryFollowRow extends ConsumerStatefulWidget {
  const SubCategoryFollowRow({
    super.key,
    required this.categoryId,
    required this.parentName,
  });

  final String categoryId;
  final String parentName;

  @override
  ConsumerState<SubCategoryFollowRow> createState() =>
      _SubCategoryFollowRowState();
}

class _SubCategoryFollowRowState extends ConsumerState<SubCategoryFollowRow>
    with GuardedActionState<SubCategoryFollowRow> {
  bool? _optimistic;
  bool _saving = false;

  Future<void> _set(bool follow) async {
    if (follow &&
        !await confirmDangerousAction(
          context,
          title: 'Follow ${widget.parentName}?',
          message:
              "This category's own permissions are replaced by "
              "${widget.parentName}'s, and so are those of the channels "
              'that follow it.',
          confirmLabel: 'Follow',
        )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _saving = true;
      _optimistic = follow;
    });
    final categoryId = widget.categoryId;
    final actions = ref.read(settingsActionsProvider);
    final ok = await guard(
      whatFailed: follow ? 'follow the parent category' : 'stop following it',
      action: () async {
        if (follow) {
          await actions.syncCategoryOverwrites(categoryId);
        } else {
          // An empty batch changes no permission; any save of its own stops a sub-category following.
          await actions.batchSetCategoryOverwrites(
            categoryId: categoryId,
            overwrites: const [],
          );
        }
        ref
          ..invalidate(categoryOverwritesProvider(categoryId))
          ..invalidate(categoryOverwritesSyncedProvider(categoryId));
      },
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (!ok) _optimistic = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final stored = ref
        .watch(categoryOverwritesSyncedProvider(widget.categoryId))
        .valueOrNull;
    if (_optimistic != null && !_saving && stored == _optimistic) {
      _optimistic = null;
    }
    final follows = _optimistic ?? stored ?? false;
    final error = actionError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsToggleRow(
          label: 'Follow ${widget.parentName}',
          description: follows
              ? 'Uses the same permissions as ${widget.parentName}.'
              : 'Has its own permissions.',
          value: follows,
          semanticLabel: 'Follow ${widget.parentName}',
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
      ],
    );
  }
}
