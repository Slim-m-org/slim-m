// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a member is told about the module behind a command or an app: whose it
/// is, whether the official registry carries it, and what an admin let it do.
/// A member meets modules only as a `/name` and an apps list, so this is where
/// a third-party program stops looking like a built-in feature.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

export '../module_detail.dart';

/// One plain sentence per approved power, in the member's terms.
List<String> moduleAboutLines(api.ModuleInfo module) {
  final hosts = module.networkHosts;
  return [
    if (module.reachesNetwork)
      hosts.isEmpty
          ? 'Sends requests to websites.'
          : 'Sends requests to ${hosts.join(', ')}.',
    if (module.posts)
      'Posts messages as whoever runs it, marked as this module.',
    if (module.capabilities.contains('kv.store'))
      'Remembers data for this space.',
    if (module.runsOnItsOwn)
      'Runs on a timer and posts as itself in a channel an admin chose.',
  ];
}

/// A small "Internet" badge for a module that can reach out, or nothing.
class ModuleNetworkBadge extends StatelessWidget {
  const ModuleNetworkBadge({super.key, required this.module});

  final api.ModuleInfo? module;

  @override
  Widget build(BuildContext context) {
    final module = this.module;
    if (module == null || !module.reachesNetwork) {
      return const SizedBox.shrink();
    }
    return const AppBadge(variant: AppBadgeVariant.warn, label: 'Internet');
  }
}

/// The info button on a module's row; opens [showModuleAboutSheet].
class ModuleAboutButton extends StatelessWidget {
  const ModuleAboutButton({super.key, required this.module});

  final api.ModuleInfo? module;

  @override
  Widget build(BuildContext context) {
    final module = this.module;
    if (module == null) return const SizedBox.shrink();
    return AppIconButton(
      icon: AppIcons.info,
      semanticLabel: 'About ${module.name}',
      tooltip: 'About ${module.name}',
      size: AppIconButtonSize.sm,
      iconSize: AppSizes.icon16,
      onPressed: () => showModuleAboutSheet(context, module),
    );
  }
}

Future<void> showModuleAboutSheet(BuildContext context, api.ModuleInfo module) {
  return showAppSheet<void>(
    context,
    builder: (context) => _AboutSheet(module: module),
  );
}

class _AboutSheet extends StatelessWidget {
  const _AboutSheet({required this.module});

  final api.ModuleInfo module;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final lines = moduleAboutLines(module);
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
            module.name,
            style: AppText.heading.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.semi,
            ),
          ),
          const SizedBox(height: AppSpacing.s4),
          Text(
            module.verified
                ? 'A module from the official registry.'
                : 'A module from outside the official registry. slim-m has not '
                      'reviewed it.',
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
          const SizedBox(height: AppSpacing.s12),
          Text(
            lines.isEmpty
                ? 'It runs on this server and can only answer what you give it.'
                : 'An admin let it:',
            style: AppText.body.copyWith(color: tokens.textPrimary),
          ),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    AppIcons.info,
                    size: AppSizes.icon16,
                    color: tokens.textSecondary,
                  ),
                  const SizedBox(width: AppSpacing.s8),
                  Expanded(
                    child: Text(
                      line,
                      style: AppText.body.copyWith(color: tokens.textPrimary),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
