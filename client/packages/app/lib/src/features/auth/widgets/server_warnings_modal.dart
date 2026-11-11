// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The acknowledge step before an account is created on a server with
/// something worth knowing about it.
///
/// Informs and nothing else: no report, no notification, only Continue or back.
/// Signing in to an account that already exists never asks, since the warnings
/// are about joining.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/server_notice.dart';

/// Every warning that applies to joining [version]'s server, in reading order.
List<ServerWarning> serverWarningsFor(Version? version) {
  if (version == null) return const [];
  return [
    ?safetyWarning(version),
    if (version.claimed == false)
      const ServerWarning(
        AppIcons.invite,
        'This Space has no members yet, so the first account becomes its '
        'administrator.',
      ),
  ];
}

/// True when the person acknowledged [warnings] and wants to continue.
Future<bool> confirmServerWarnings(
  BuildContext context,
  List<ServerWarning> warnings,
) async {
  final agreed = await showAppSheet<bool>(
    context,
    semanticLabel: 'Before you create an account',
    builder: (context) => _WarningsBody(warnings: warnings),
  );
  return agreed ?? false;
}

class _WarningsBody extends StatelessWidget {
  const _WarningsBody({required this.warnings});

  final List<ServerWarning> warnings;

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
          Text(
            'Before you create an account',
            style: AppText.body.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.semi,
            ),
          ),
          const SizedBox(height: AppSpacing.s12),
          for (final warning in warnings)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.s8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    warning.icon,
                    size: AppSizes.icon16,
                    color: tokens.textSecondary,
                  ),
                  const SizedBox(width: AppSpacing.s8),
                  Expanded(
                    child: Text(
                      warning.message,
                      style: AppText.body.copyWith(color: tokens.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: AppSpacing.s8),
          Row(
            children: [
              Expanded(
                child: AppButton(
                  label: 'Cancel',
                  variant: AppButtonVariant.ghost,
                  onPressed: () => Navigator.of(context).pop(false),
                ),
              ),
              const SizedBox(width: AppSpacing.s8),
              Expanded(
                child: AppButton(
                  label: 'Continue',
                  onPressed: () => Navigator.of(context).pop(true),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
