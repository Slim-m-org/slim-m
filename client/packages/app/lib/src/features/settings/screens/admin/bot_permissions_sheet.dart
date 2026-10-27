// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The permission editor sheet for one bot's managed role.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../providers/admin_providers.dart';
import '../../../../providers/providers.dart';
import '../../../../widgets/run_guarded.dart';
import '../../../members/widgets/bot_permission_toggles.dart';

/// Opens the permission editor for one bot's managed role.
Future<void> showBotPermissionsSheet(BuildContext context, api.Bot bot) {
  return showAppSheet<void>(
    context,
    scrolls: true,
    builder: (context) => _BotPermissionsSheet(bot: bot),
  );
}

class _BotPermissionsSheet extends ConsumerStatefulWidget {
  const _BotPermissionsSheet({required this.bot});

  final api.Bot bot;

  @override
  ConsumerState<_BotPermissionsSheet> createState() =>
      _BotPermissionsSheetState();
}

class _BotPermissionsSheetState extends ConsumerState<_BotPermissionsSheet>
    with GuardedActionState<_BotPermissionsSheet> {
  late int _permissions = widget.bot.permissions;
  bool _submitting = false;

  Future<void> _submit() async {
    clearActionError();
    setState(() => _submitting = true);
    final ok = await guard(
      whatFailed: "save ${widget.bot.displayName}'s permissions",
      action: () => ref
          .read(apiProvider)
          .setBotPermissions(widget.bot.userId, _permissions),
    );
    if (!mounted) return;
    if (!ok) {
      setState(() => _submitting = false);
      return;
    }
    ref.invalidate(botsProvider);
    Navigator.of(context).pop();
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  "${widget.bot.displayName}'s permissions",
                  style: AppText.heading.copyWith(
                    color: tokens.textPrimary,
                    fontWeight: AppWeights.semi,
                  ),
                ),
              ),
              AppIconButton(
                icon: AppIcons.dismiss,
                semanticLabel: 'Close',
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: AppSpacing.s4),
                  Text(
                    'You can never grant more than you hold yourself.',
                    style: AppText.caption.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.s8),
                  BotPermissionToggles(
                    value: _permissions,
                    onChanged: (v) => setState(() => _permissions = v),
                  ),
                ],
              ),
            ),
          ),
          if (actionError != null) ...[
            const SizedBox(height: AppSpacing.s8),
            AppErrorState(message: actionError!),
          ],
          const SizedBox(height: AppSpacing.s12),
          AppButton(
            label: _submitting ? 'Saving...' : 'Save changes',
            variant: AppButtonVariant.primary,
            full: true,
            disabled: _submitting,
            onPressed: _submit,
          ),
        ],
      ),
    );
  }
}
