// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A server's name and icon as its own container knows them.
library;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/space_icon.dart';
import '../../../providers/server_info.dart';
import '../providers/account_providers.dart';

typedef ServerIdentityBuilder =
    Widget Function(BuildContext context, String name, int? iconUpdatedAt);

/// Builds [builder] with [entry]'s name and icon as its own container holds
/// them: an inactive account's are fetched with its session, not the one on screen.
///
/// It listens to that container and mounts no scope for it. The root's scope
/// stays the only one a container has (docs/internals.md, account scopes).
class ServerIdentity extends StatelessWidget {
  const ServerIdentity({super.key, required this.entry, required this.builder});

  final AccountEntry entry;
  final ServerIdentityBuilder builder;

  @override
  Widget build(BuildContext context) => _FromContainer(
    container: entry.container,
    provider: serverInfoProvider,
    builder: (context, info) => builder(
      context,
      info.valueOrNull?.displayName ?? entry.account.serverUrl.host,
      info.valueOrNull?.iconUpdatedAt,
    ),
  );
}

/// Rebuilds with what [provider] holds in [container], which is not the
/// container this widget sits under.
class _FromContainer<T> extends StatefulWidget {
  const _FromContainer({
    super.key,
    required this.container,
    required this.provider,
    required this.builder,
  });

  final ProviderContainer container;
  final ProviderListenable<T> provider;
  final Widget Function(BuildContext context, T value) builder;

  @override
  State<_FromContainer<T>> createState() => _FromContainerState<T>();
}

class _FromContainerState<T> extends State<_FromContainer<T>> {
  late ProviderSubscription<T> _held;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(_FromContainer<T> old) {
    super.didUpdateWidget(old);
    if (old.container == widget.container && old.provider == widget.provider) {
      return;
    }
    _held.close();
    _listen();
  }

  void _listen() =>
      _held = widget.container.listen<T>(widget.provider, (_, _) => _changed());

  /// That container's own scope refreshes it while building, when no widget
  /// outside that scope may be marked; such a change is taken after the frame.
  void _changed() {
    final building =
        SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks;
    if (!building) return setState(() {});
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _held.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _held.read());
}

/// The server's icon, or its first letter on the placeholder square.
class ServerIconTile extends StatelessWidget {
  const ServerIconTile({
    super.key,
    required this.entry,
    required this.name,
    required this.iconUpdatedAt,
    required this.size,
  });

  /// Whose icon: it is fetched through this account's container.
  final AccountEntry entry;
  final String name;
  final int? iconUpdatedAt;
  final double size;

  @override
  Widget build(BuildContext context) {
    final at = iconUpdatedAt;
    if (at != null) {
      return _FromContainer(
        container: entry.container,
        provider: spaceIconBytesProvider(at),
        builder: (context, bytes) =>
            SpaceIconImage(bytes: bytes.valueOrNull, size: size),
      );
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
