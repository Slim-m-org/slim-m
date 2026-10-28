// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space's connection to the server, shown beside its name in the rail
/// header.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/sync_controller.dart';
import '../providers/sync_failure.dart';

/// Built on [AppStatusDotPainter] rather than [AppStatusDot], whose label
/// always names a person's presence, the wrong claim about a server link.
///
/// The shapes mirror [AppStatusDot.shapeOf] so live and offline still differ
/// with the colour removed. Offline alone carries the warn tone; connecting
/// is transient and stays neutral. A live link over the server's own network
/// shows a plug in the accent colour instead of the dot, so it can be told
/// apart from the internet route at a glance.
class SpaceConnectionDot extends StatelessWidget {
  const SpaceConnectionDot({
    super.key,
    required this.status,
    this.failure,
    this.direct = false,
    this.haloed = false,
    this.voicePingMs,
  });

  final SyncStatus status;

  /// Why sync is down, when something knows: a refused session and an
  /// unreachable server look identical here and recover differently.
  final SyncFailure? failure;

  /// Requests reach the server over its own network.
  final bool direct;

  /// Round trip to the voice server while in a call; added to the tooltip.
  final int? voicePingMs;

  /// Ring cut-out in the rail colour, for a badge drawn over a Space icon.
  final bool haloed;

  static const Map<SyncStatus, AppStatusShape> _shapeOf = {
    SyncStatus.live: AppStatusShape.filledDisc,
    SyncStatus.connecting: AppStatusShape.triangle,
    SyncStatus.offline: AppStatusShape.hollowRing,
  };

  static const double _size = 8;
  static const double _plugSize = 12;

  /// Outer diameter including the halo, so a caller can centre the badge.
  static const double haloedSize = _size + 2 * AppAvatarGeometry.dotHalo;

  /// [haloedSize] for the badge showing the plug.
  static const double haloedPlugSize =
      _plugSize + 2 * AppAvatarGeometry.dotHalo;

  bool get _showsPlug => direct && status == SyncStatus.live;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final label = _showsPlug
        ? 'Connected over your local network'
        : connectionLabel(status, failure);
    final Widget glyph = _showsPlug
        ? Icon(AppIcons.localNetwork, size: _plugSize, color: tokens.accent)
        : CustomPaint(
            size: const Size.square(_size),
            painter: AppStatusDotPainter(
              shape: _shapeOf[status]!,
              color: switch (status) {
                SyncStatus.live => tokens.status.online,
                SyncStatus.connecting => tokens.textSecondary,
                SyncStatus.offline => tokens.warnText,
              },
              backgroundColor: tokens.surfaceSunken,
            ),
          );
    final ping = voicePingMs;
    final dot = Tooltip(
      message: ping == null ? label : '$label\nVoice ping $ping ms',
      child: Semantics(
        label: label,
        // Cross-fades on [AppStatusDot]'s own clock; the key scopes the swap to the state.
        child: AnimatedSwitcher(
          duration: AppMotion.reduced(context, AppMotion.fast),
          child: KeyedSubtree(
            key: ValueKey((status, _showsPlug)),
            child: glyph,
          ),
        ),
      ),
    );
    if (!haloed) return dot;
    const halo = AppAvatarGeometry.dotHalo;
    final size = _showsPlug ? _plugSize : _size;
    // A triangle fills its square and its weight sits low, so inside a round halo it shrinks and rises to its centroid.
    final inset = status == SyncStatus.connecting ? 1.0 : 0.0;
    return Container(
      padding: EdgeInsets.fromLTRB(
        halo + inset,
        halo,
        halo + inset,
        halo + 2 * inset,
      ),
      decoration: BoxDecoration(
        color: tokens.surfaceSunken,
        shape: BoxShape.circle,
      ),
      child: SizedBox.square(dimension: size - 2 * inset, child: dot),
    );
  }
}
