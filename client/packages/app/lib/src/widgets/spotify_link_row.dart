// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the Spotify link is doing, in place under its Settings switch
/// (decision 0056): waiting on the browser, connecting, who is connected, or
/// the failure with a way forward. Nothing is shown while unlinked.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../spotify/spotify_link.dart';
import '../spotify/spotify_link_status.dart';
import 'settings_section_header.dart';

class SpotifyLinkRow extends ConsumerWidget {
  const SpotifyLinkRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(spotifyLinkStatusProvider);
    final linker = ref.read(spotifyLinkerProvider);
    return switch (status) {
      SpotifyUnlinked() => const SizedBox.shrink(),
      SpotifyWaiting() => _Line(
        text: 'Waiting for Spotify. Finish signing in, then come back.',
        action: 'Cancel',
        onAction: linker.cancel,
      ),
      SpotifyConnecting() => const _Line(text: 'Connecting to Spotify...'),
      SpotifyConnected(:final text) => _Line(
        text: text,
        icon: AppIcons.check,
        action: 'Disconnect',
        onAction: () =>
            ref.read(shareSpotifyProvider.notifier).setEnabled(false),
      ),
      SpotifyFailed(:final message) => SettingsCardBlock(
        children: [
          AppErrorState(
            message: message,
            onRetry: () =>
                ref.read(shareSpotifyProvider.notifier).setEnabled(true),
            onDismiss: linker.dismissFailure,
          ),
        ],
      ),
    };
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.text, this.icon, this.action, this.onAction});

  final String text;
  final IconData? icon;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return SettingsSubRow(
      label: text,
      semanticLabel: text,
      leading: icon == null
          ? null
          : Icon(icon, size: AppSizes.icon16, color: tokens.accent),
      trailing: action == null
          ? null
          : AppButton(
              label: action!,
              variant: AppButtonVariant.ghost,
              size: AppButtonSize.sm,
              onPressed: onAction,
            ),
    );
  }
}
