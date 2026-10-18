// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Accounts from other services a member links to their profile. Only Discord.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../external_link.dart';
import '../../../providers/app_lifecycle.dart';
import '../../../providers/providers.dart';
import '../../../widgets/run_guarded.dart';
import '../providers/linked_accounts.dart';
import 'settings_detail_row.dart';
import 'settings_refresh_button.dart';
import 'settings_section_header.dart';

class ConnectionsSection extends ConsumerStatefulWidget {
  const ConnectionsSection({super.key});

  @override
  ConsumerState<ConnectionsSection> createState() => _ConnectionsSectionState();
}

class _ConnectionsSectionState extends ConsumerState<ConnectionsSection>
    with GuardedActionState<ConnectionsSection> {
  bool _busy = false;

  Future<void> _link() async {
    setState(() => _busy = true);
    await guard(
      whatFailed: 'start linking Discord',
      action: () async {
        try {
          final url = await ref.read(apiProvider).startDiscordLink();
          await openExternalHttpUrl(
            url,
            launcher: ref.read(externalUrlLauncherProvider),
          );
        } on api.NotConfiguredException {
          ref.read(discordLinkUnavailableProvider.notifier).state = true;
        }
      },
    );
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _unlink() async {
    setState(() => _busy = true);
    final ok = await guard(
      whatFailed: 'unlink Discord',
      action: () => ref.read(apiProvider).unlinkDiscord(),
    );
    if (ok) ref.invalidate(myLinkedAccountsProvider);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(appFocusedProvider, (was, focused) {
      if (focused && was == false) ref.invalidate(myLinkedAccountsProvider);
    });
    final links = ref.watch(myLinkedAccountsProvider);
    final unavailable = ref.watch(discordLinkUnavailableProvider);
    final discord = links.valueOrNull
        ?.where((link) => link.isDiscord)
        .firstOrNull;
    if (unavailable && discord == null) return const SizedBox.shrink();

    return SettingsSectionCard(
      title: 'Connections',
      description: 'Accounts shown on your profile.',
      trailing: SettingsRefreshButton(
        label: 'Refresh connections',
        onPressed: () => ref.invalidate(myLinkedAccountsProvider),
      ),
      children: [
        if (links.hasError && discord == null)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s16),
            child: AppErrorState(
              message: 'Could not load your connections.',
              onRetry: () => ref.invalidate(myLinkedAccountsProvider),
            ),
          )
        else if (!links.hasValue)
          const Padding(
            padding: EdgeInsets.all(AppSpacing.s16),
            child: LinearProgressIndicator(),
          )
        else
          SettingsDetailRow(
            icon: AppIcons.link,
            title: 'Discord',
            detail: discord == null ? 'Not linked' : discordLabel(discord),
            error: actionError,
            onErrorDismiss: clearActionError,
            trailing: AppButton(
              label: discord == null ? 'Link' : 'Unlink',
              size: AppButtonSize.sm,
              variant: discord == null
                  ? AppButtonVariant.secondary
                  : AppButtonVariant.danger,
              disabled: _busy,
              onPressed: () => unawaited(discord == null ? _link() : _unlink()),
            ),
          ),
      ],
    );
  }
}

/// The display name beside the username when there is one.
String discordLabel(api.LinkedAccount link) => link.displayName == null
    ? link.username
    : '${link.displayName} (${link.username})';
