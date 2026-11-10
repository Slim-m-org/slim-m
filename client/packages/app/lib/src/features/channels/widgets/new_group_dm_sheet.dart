// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sheet for starting a group DM: pick 2 to 9 people, optionally name it.
///
/// Rule 4 of `docs/design/desktop-vs-mobile.md`: a short task with a submit,
/// so a bottom sheet under 600 and a centred dialog above it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../api_failure.dart';
import '../../../entity_name.dart';
import '../../../ids.dart';
import '../../../routing/routes.dart';
import '../providers/group_dm.dart';
import 'group_dm_people_list.dart';

const _startTask = 'start the group';

Future<void> showNewGroupDmSheet(BuildContext context) =>
    showAppSheet<void>(context, builder: (_) => const _NewGroupDmSheet());

class _NewGroupDmSheet extends ConsumerStatefulWidget {
  const _NewGroupDmSheet();

  @override
  ConsumerState<_NewGroupDmSheet> createState() => _NewGroupDmSheetState();
}

class _NewGroupDmSheetState extends ConsumerState<_NewGroupDmSheet> {
  final _picked = <String>{};
  final _name = TextEditingController();
  final _createId = RetryId(newChannelId);
  bool _submitting = false;
  String? _error;

  /// Others besides the caller, so the group holds this many plus one.
  static const _maxOthers = groupDmMaxPeople - 1;
  static const _minOthers = groupDmMinPeople - 1;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _nameOk => _name.text.trim().isEmpty || entityNameValid(_name.text);
  bool get _canSubmit =>
      !_submitting && _picked.length >= _minOthers && _nameOk;

  String get _buttonLabel {
    if (_submitting) return 'Starting...';
    if (_picked.length < _minOthers) {
      return 'Pick ${_minOthers - _picked.length} more';
    }
    if (!_nameOk) return 'Name is too long';
    return 'Start group with ${_picked.length + 1} people';
  }

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    final container = ProviderScope.containerOf(context, listen: false);
    final router = GoRouter.of(context);
    final userIds = _picked.toList();
    final name = _name.text.trim().isEmpty ? null : _name.text.trim();
    try {
      final id = await createGroupDm(
        container,
        userIds,
        id: _createId.forRequest((
          people: (userIds.toList()..sort()).join(','),
          name: name,
        )),
        name: name,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      router.go(Routes.channel(id));
    } on api.ApiException catch (e, stack) {
      api.reportFailure(api.LogTag.ui, _startTask, e, stack);
      if (mounted) {
        setState(
          () => _error = e is api.ForbiddenException
              ? describeGroupDmFailure(_startTask, e)
              : describeApiFailure(_startTask, e),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'New group message',
              style: AppText.heading.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.semi,
              ),
            ),
            const SizedBox(height: AppSpacing.s4),
            Text(
              'Pick $_minOthers to $_maxOthers people. Up to $groupDmMaxPeople '
              'can be in a group, you included.',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
            const SizedBox(height: AppSpacing.s12),
            GroupDmPeopleList(
              exclude: const {},
              selected: _picked,
              full: _picked.length >= _maxOthers,
              onTap: (id) => setState(() {
                if (!_picked.remove(id)) _picked.add(id);
              }),
            ),
            const SizedBox(height: AppSpacing.s12),
            AppInput(
              counterMax: entityNameMaxChars,
              controller: _name,
              placeholder: 'Group name (optional)',
              semanticLabel: 'Group name',
              onChanged: (_) => setState(() {}),
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.s8),
              AppErrorState(message: _error!),
            ],
            const SizedBox(height: AppSpacing.s12),
            AppButton(
              label: _buttonLabel,
              // A dimmed primary leaves its dark label low-contrast on the dark theme.
              variant: _canSubmit
                  ? AppButtonVariant.primary
                  : AppButtonVariant.secondary,
              full: true,
              disabled: !_canSubmit,
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }
}
