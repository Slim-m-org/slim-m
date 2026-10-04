// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the update chip opens on a package-managed install (rpm, deb,
/// flatpak): the new version exists, the package manager is how it arrives,
/// and the release page stays one tap away for anyone who wants to read it or
/// install by hand. Decision 0020: the app does not fake an update the
/// platform cannot do, and a repo can lag the release, so GitHub is never the
/// lead here.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:url_launcher/url_launcher.dart';

import '../providers/toasts.dart';
import 'update_check.dart';

/// Opens a release page; a provider so a test can see the url without a
/// platform channel.
final releaseLauncherProvider = Provider<Future<void> Function(Uri)>(
  (ref) =>
      (uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
);

/// Whether [format] is replaced by a package manager, never from GitHub.
bool isPackageManaged(InstallFormat format) =>
    format == InstallFormat.rpm ||
    format == InstallFormat.deb ||
    format == InstallFormat.flatpak;

/// The one sentence naming how [format] gets an update.
String packageManagerSentence(InstallFormat format) =>
    format == InstallFormat.flatpak
    ? 'Update with Flatpak.'
    : 'Update with your package manager.';

/// The command that updates [format], or null where this app does not know
/// the package name.
String? packageManagerCommand(InstallFormat format) => switch (format) {
  InstallFormat.rpm => 'sudo dnf upgrade --refresh slim-m-client',
  InstallFormat.flatpak => 'flatpak update top.npcserver.slimm',
  _ => null,
};

/// The chip tooltip and menu row for a package-managed [update].
String packageManagerLabel(ClientUpdate update) =>
    update.format == InstallFormat.flatpak
    ? 'Update ${update.version} with Flatpak'
    : 'Update ${update.version} with your package manager';

Future<void> showUpdatePackageView(
  BuildContext context, {
  required ClientUpdate update,
}) => showAppSheet<void>(
  context,
  builder: (_) => UpdatePackageView(update: update),
);

class UpdatePackageView extends ConsumerWidget {
  const UpdatePackageView({super.key, required this.update});

  final ClientUpdate update;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final command = packageManagerCommand(update.format);
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
            'Version ${update.version} is available',
            style: AppText.body.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.semi,
            ),
          ),
          const SizedBox(height: AppSpacing.s8),
          Text(
            packageManagerSentence(update.format),
            style: AppText.body.copyWith(color: tokens.textSecondary),
          ),
          if (command != null) ...[
            const SizedBox(height: AppSpacing.s12),
            _CommandRow(command: command),
          ],
          const SizedBox(height: AppSpacing.s16),
          Row(
            children: [
              Expanded(
                child: AppButton(
                  label: 'Check GitHub',
                  icon: AppIcons.externalLink,
                  variant: AppButtonVariant.ghost,
                  onPressed: () => unawaited(_check(ref)),
                ),
              ),
              const SizedBox(width: AppSpacing.s8),
              Expanded(
                child: AppButton(
                  label: 'Close',
                  variant: AppButtonVariant.soft,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _check(WidgetRef ref) async {
    final uri = Uri.tryParse(update.releaseUrl);
    if (uri == null) return;
    await ref.read(releaseLauncherProvider)(uri);
  }
}

class _CommandRow extends ConsumerWidget {
  const _CommandRow({required this.command});

  final String command;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        border: Border.all(color: tokens.borderSubtle),
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.s12,
                vertical: AppSpacing.s8,
              ),
              child: SelectableText(
                command,
                style: AppText.code.copyWith(color: tokens.textPrimary),
              ),
            ),
          ),
          AppIconButton(
            icon: AppIcons.copy,
            semanticLabel: 'Copy command',
            size: AppIconButtonSize.sm,
            onPressed: () {
              unawaited(Clipboard.setData(ClipboardData(text: command)));
              ref
                  .read(toastsProvider.notifier)
                  .show('Command copied.', severity: AppToastSeverity.success);
            },
          ),
        ],
      ),
    );
  }
}
