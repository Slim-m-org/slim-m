// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A server's name and icon as its own container knows them.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/space_icon.dart';
import '../../channels/widgets/channel_rail_frame.dart' show serverInfoProvider;
import '../providers/account_providers.dart';

typedef ServerIdentityBuilder =
    Widget Function(BuildContext context, String name, int? iconUpdatedAt);

/// Builds [builder] inside [entry]'s container, because an inactive account's
/// name and icon are fetched with its own session, not the one on screen.
class ServerIdentityScope extends StatelessWidget {
  const ServerIdentityScope({
    super.key,
    required this.entry,
    required this.builder,
  });

  final AccountEntry entry;
  final ServerIdentityBuilder builder;

  @override
  Widget build(BuildContext context) => UncontrolledProviderScope(
    container: entry.container,
    child: Consumer(
      builder: (context, ref, _) {
        final info = ref.watch(serverInfoProvider).valueOrNull;
        return builder(
          context,
          info?.displayName ?? entry.account.serverUrl.host,
          info?.iconUpdatedAt,
        );
      },
    ),
  );
}

/// The server's icon, or its first letter on the placeholder square.
class ServerIconTile extends StatelessWidget {
  const ServerIconTile({
    super.key,
    required this.name,
    required this.iconUpdatedAt,
    required this.size,
  });

  final String name;
  final int? iconUpdatedAt;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (iconUpdatedAt != null) {
      return SpaceIcon(updatedAt: iconUpdatedAt, size: size);
    }
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return SpaceIconFrame(
      size: size,
      child: Center(
        child: Text(
          name.isEmpty ? '?' : name.characters.first.toUpperCase(),
          style: AppText.caption.copyWith(color: tokens.textSecondary),
        ),
      ),
    );
  }
}
