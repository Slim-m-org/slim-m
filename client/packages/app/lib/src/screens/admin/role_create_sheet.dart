// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Creating a role is a short task with one field: a name. Everything else
/// (permissions, members, mentionable) is configured afterward on the
/// role's own detail once it exists - see `role_detail.dart`. Replaces the
/// old full "New role" form, which duplicated the permissions list the
/// detail view now owns. Desktop-vs-mobile rule 4 (a short task with a
/// submit).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../api_failure.dart';
import '../../providers/admin_providers.dart';
import '../../providers/providers.dart';
import '../../action_labels.dart';

Future<void> showCreateRoleSheet(BuildContext context) {
  return showAppSheet<void>(
    context,
    builder: (context) => const _CreateRoleSheet(),
  );
}

class _CreateRoleSheet extends ConsumerStatefulWidget {
  const _CreateRoleSheet();

  @override
  ConsumerState<_CreateRoleSheet> createState() => _CreateRoleSheetState();
}

class _CreateRoleSheetState extends ConsumerState<_CreateRoleSheet> {
  final TextEditingController _name = TextEditingController();
  bool _submitting = false;
  String? _error;

  bool get _canSubmit => !_submitting && _name.text.trim().isNotEmpty;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final role = await ref
          .read(apiProvider)
          .createRole(name: _name.text.trim(), permissions: 0);
      if (context.mounted) ref.invalidate(rolesProvider);
      if (mounted) Navigator.of(context).pop(role.id);
    } on api.ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = describeApiFailure('create the role', e);
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ActionLabels.createRole,
            style: AppText.heading.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.semi,
            ),
          ),
          const SizedBox(height: AppSpacing.s4),
          Text(
            'Set its permissions, members and display afterward.',
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
          const SizedBox(height: AppSpacing.s16),
          AppInput(
            controller: _name,
            placeholder: 'Role name',
            autofocus: true,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _canSubmit ? _submit() : null,
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.s8),
            AppErrorState(message: _error!),
          ],
          const SizedBox(height: AppSpacing.s16),
          AppButton(
            label: _submitting ? 'Creating...' : 'Create role',
            variant: AppButtonVariant.primary,
            full: true,
            disabled: !_canSubmit,
            onPressed: _submit,
          ),
        ],
      ),
    );
  }
}
