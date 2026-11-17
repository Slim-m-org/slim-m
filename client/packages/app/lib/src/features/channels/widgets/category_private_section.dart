// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The top of a category's permissions sheet: a Private category switch,
/// who can see it, and what a save here does not reach (decision 0124).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart';

import '../../../permissions.dart';
import '../../../providers/admin_providers.dart';
import '../../../providers/providers.dart' show sessionProvider;
import '../../../widgets/confirm_dialog.dart';
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
  });

  final String categoryId;
  final String name;
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
        // An administrator sees it anyway; anyone else keeps the view they are taking away.
        final admin = ref
            .read(myPermissionsProvider)
            .hasPermission(Perm.administrator);
        await ref
            .read(viewAccessWriterProvider)
            .write(
              target,
              private
                  ? privateEdits(
                      existing,
                      everyoneRoleId: everyone.id,
                      selfId: admin
                          ? null
                          : ref.read(sessionProvider).tokens?.userId,
                    )
                  : publicEdits(existing, everyoneRoleId: everyone.id),
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
    return SettingsSectionCard(
      topGap: 0,
      children: [
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
      ],
    );
  }
}
