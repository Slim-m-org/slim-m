// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Spotify rows of the Connections card: link state in place (decisions
/// 0044, 0056). The show-track switch is in the Activity card.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../spotify/spotify_link.dart';
import '../../../spotify/spotify_link_status.dart';
import 'settings_detail_row.dart';
import 'settings_section_header.dart';

/// The card children for Spotify.
List<Widget> spotifyConnectionChildren(WidgetRef ref) {
  final status = ref.watch(spotifyLinkStatusProvider);
  return [
    const _SpotifyLinkRow(),
    if (status is SpotifyFailed) _SpotifyFailure(message: status.message),
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
      leading: const SettingsBrandTile(BrandService.spotify),
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
