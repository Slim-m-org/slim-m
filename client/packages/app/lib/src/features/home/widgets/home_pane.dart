// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the conversation pane shows with no channel chosen.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../whats_new/providers/whats_new_controller.dart';
import '../../../routing/breakpoints.dart';
import '../../../widgets/space_icon.dart';
import '../../channels/widgets/channel_rail_frame.dart' show serverInfoProvider;
import '../../first_run/providers/first_run_controller.dart';
import 'home_shortcuts.dart';
import 'home_unread.dart';
import 'home_update_card.dart';

const _columnWidth = 420.0;
const _markSize = 48.0;
const _fallbackName = 'slim-m';

/// One centred column: the Space's identity, then whatever the moment calls
/// for. Cards run the full column so their edges are its edges.
class HomePane extends ConsumerStatefulWidget {
  const HomePane({super.key});

  @override
  ConsumerState<HomePane> createState() => _HomePaneState();
}

class _HomePaneState extends ConsumerState<HomePane> {
  late final WhatsNewHomeHosts _hosts;

  @override
  void initState() {
    super.initState();
    _hosts = ref.read(whatsNewHomeHostsProvider)..attach();
  }

  @override
  void dispose() {
    _hosts.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final offered = ref.watch(
      firstRunControllerProvider.select((s) => s.offered),
    );
    final info = ref.watch(serverInfoProvider).valueOrNull;
    final name = info?.displayName ?? _fallbackName;
    final description = info?.spaceDescription?.trim();
    final iconUpdatedAt = info?.iconUpdatedAt;
    // Keycaps only where a keyboard is; a finger cannot press any of these.
    final keyboard = !AppTouchTargets.of(context);
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.s24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _columnWidth),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: AppSpacing.s24,
                  children: [
                    _Identity(
                      title: offered ? 'Welcome to $name' : name,
                      subtitle: (description?.isNotEmpty ?? false)
                          ? description!
                          : offered
                          ? 'A short setup gets your profile and alerts ready.'
                          : 'Pick a channel to start reading.',
                      iconUpdatedAt: iconUpdatedAt,
                    ),
                    if (offered) const _SetupOffer(),
                    const HomeUpdateCard(),
                    if (!offered) const HomeUnread(),
                    if (!offered && keyboard) const HomeShortcuts(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Identity extends StatelessWidget {
  const _Identity({
    required this.title,
    required this.subtitle,
    required this.iconUpdatedAt,
  });

  final String title;
  final String subtitle;
  final int? iconUpdatedAt;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      spacing: AppSpacing.s8,
      children: [
        if (iconUpdatedAt != null)
          SpaceIcon(updatedAt: iconUpdatedAt, size: _markSize)
        else
          Container(
            width: _markSize,
            height: _markSize,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: tokens.surfaceRaised,
              shape: BoxShape.circle,
            ),
            child: Icon(AppIcons.hash, size: 26, color: tokens.textSecondary),
          ),
        Text(
          title,
          textAlign: TextAlign.center,
          style: AppText.title.copyWith(color: tokens.textPrimary),
        ),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: AppText.body.copyWith(color: tokens.textSecondary),
        ),
      ],
    );
  }
}

class _SetupOffer extends ConsumerWidget {
  const _SetupOffer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final beside = LayoutClass.of(context).showsBothPanes;
    return Column(
      spacing: AppSpacing.s16,
      children: [
        AppButton(
          label: 'Get started',
          variant: AppButtonVariant.primary,
          size: AppButtonSize.lg,
          onPressed: () =>
              ref.read(firstRunControllerProvider.notifier).start(),
        ),
        Text(
          beside
              ? 'Your channels are in the list on the left.'
              : 'Your channels are in the list.',
          textAlign: TextAlign.center,
          style: AppText.body.copyWith(color: tokens.textSecondary),
        ),
      ],
    );
  }
}
