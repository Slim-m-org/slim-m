// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Spotify rows of the Connections card: link state in place, and once
/// linked, the switch for whether the track is shown (decisions 0044, 0056).
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../spotify/spotify_link.dart';
import '../../../spotify/spotify_link_status.dart';
import 'settings_detail_row.dart';
import 'settings_section_header.dart';
import 'settings_toggle_row.dart';

/// The card children for Spotify; only the link row while unlinked.
List<Widget> spotifyConnectionChildren(WidgetRef ref) {
  final status = ref.watch(spotifyLinkStatusProvider);
  return [
    const _SpotifyLinkRow(),
    if (status is SpotifyFailed) _SpotifyFailure(message: status.message),
    if (status is SpotifyConnected) const _ShowTrackRow(),
  ];
}

class _SpotifyLinkRow extends ConsumerWidget {
  const _SpotifyLinkRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(spotifyLinkStatusProvider);
    final controller = ref.read(shareSpotifyProvider.notifier);
    final connecting = status is SpotifyConnecting;
    final (label, danger, onPressed) = switch (status) {
      SpotifyConnected() => ('Unlink', true, controller.disconnect),
      SpotifyWaiting() => (
        'Cancel',
        false,
        ref.read(spotifyLinkerProvider).cancel,
      ),
      _ => ('Link', false, controller.connect),
    };
    return SettingsDetailRow(
      icon: AppIcons.music,
      title: 'Spotify',
      detail: _detail(status),
      detailMaxLines: status is SpotifyConnected ? 1 : null,
      trailing: connecting
          ? null
          : AppButton(
              label: label,
              size: AppButtonSize.sm,
              variant: danger
                  ? AppButtonVariant.danger
                  : AppButtonVariant.secondary,
              onPressed: () => unawaited(onPressed()),
            ),
    );
  }

  static String _detail(SpotifyLinkStatus status) => switch (status) {
    SpotifyConnected(:final name) => name ?? 'Linked',
    SpotifyWaiting() => 'Finish signing in, then come back.',
    SpotifyConnecting() => 'Connecting...',
    _ => 'Not linked',
  };
}

class _SpotifyFailure extends ConsumerWidget {
  const _SpotifyFailure({required this.message});

  final String message;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SettingsCardBlock(
    children: [
      AppErrorState(
        message: message,
        onRetry: () =>
            unawaited(ref.read(shareSpotifyProvider.notifier).connect()),
        onDismiss: ref.read(spotifyLinkerProvider).dismissFailure,
      ),
    ],
  );
}

class _ShowTrackRow extends ConsumerWidget {
  const _ShowTrackRow();

  /// Fills the icon tile and gap of the [SettingsDetailRow]s beside it.
  static const _lead = AppSizes.icon32 + 14 - AppSpacing.s8;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: SettingsToggleRow(
      leading: const SizedBox(width: _lead),
      label: 'Show my Spotify track',
      description: 'Shows your track even when you play on another device.',
      value: ref.watch(shareSpotifyProvider),
      onChanged: (value) =>
          ref.read(shareSpotifyProvider.notifier).setEnabled(value),
      semanticLabel: 'Show my Spotify track',
    ),
  );
}
