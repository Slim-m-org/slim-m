// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Steam rows of the Connections card: link state in place (decision
/// 0115). The sharing switch is in the Activity card.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/steam_connection.dart';
import '../providers/steam_link_finish.dart';
import 'discord_link_code_sheet.dart';
import 'settings_detail_row.dart';
import 'settings_section_header.dart';

/// The card children for Steam.
List<Widget> steamConnectionChildren(WidgetRef ref, api.LinkedAccount? steam) {
  final status = ref.watch(steamLinkStatusProvider);
  return [
    _SteamLinkRow(steam: steam),
    if (steam == null && status is! SteamLinkFinishing) const _SteamCodeRow(),
    if (status is SteamLinkFailed) _SteamFailure(message: status.message),
  ];
}

class _SteamLinkRow extends ConsumerWidget {
  const _SteamLinkRow({required this.steam});

  final api.LinkedAccount? steam;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(steamConnectionProvider);
    final finishing = ref.watch(steamLinkStatusProvider) is SteamLinkFinishing;
    final controller = ref.read(steamConnectionProvider.notifier);
    return SettingsDetailRow(
      icon: AppIcons.playing,
      title: 'Steam',
      detail: finishing
          ? 'Finishing...'
          : steam == null
          ? 'Not linked'
          : steam!.username,
      detailMaxLines: steam == null ? null : 1,
      error: connection.error,
      onErrorDismiss: controller.dismissError,
      trailing: AppButton(
        label: steam == null ? 'Link' : 'Unlink',
        size: AppButtonSize.sm,
        variant: steam == null
            ? AppButtonVariant.secondary
            : AppButtonVariant.danger,
        disabled: connection.busy || finishing,
        onPressed: () =>
            unawaited(steam == null ? controller.link() : controller.unlink()),
      ),
    );
  }
}

class _SteamCodeRow extends StatelessWidget {
  const _SteamCodeRow();

  @override
  Widget build(BuildContext context) => SettingsDetailRow(
    icon: AppIcons.clipboardPaste,
    title: 'Steam link code',
    detail: 'Paste the code from the browser page.',
    trailing: AppButton(
      label: 'Enter code',
      size: AppButtonSize.sm,
      variant: AppButtonVariant.secondary,
      onPressed: () => unawaited(showSteamLinkCodeSheet(context)),
    ),
  );
}

class _SteamFailure extends ConsumerWidget {
  const _SteamFailure({required this.message});

  final String message;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SettingsCardBlock(
    children: [
      AppErrorState(
        message: message,
        onDismiss: () => ref
            .read(steamLinkStatusProvider.notifier)
            .set(const SteamLinkIdle()),
      ),
    ],
  );
}
