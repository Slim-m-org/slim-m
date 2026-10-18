// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "In a call on SERVER", shown while another account holds a live call.
/// See docs/decisions/0068-multiple-servers-in-one-app.md.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../channels/widgets/compact_channel_app_bar.dart';
import '../providers/account_providers.dart';
import 'account_server_label.dart';

/// Mounted once by `appChromeBuilder`, top-centre like the web update pill and
/// below the app bar on a narrow window. Tapping it returns to the call.
class AccountCallPill extends ConsumerWidget {
  const AccountCallPill({super.key});

  static const Key pillKey = Key('account_call_pill');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entry = ref.watch(accountsSnapshotProvider).callElsewhere;
    if (entry == null) return const SizedBox.shrink();
    final clearOfHeader = MediaQuery.sizeOf(context).width < kCompactWidth
        ? CompactChannelAppBar.height
        : 0.0;
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.all(
            AppSpacing.s16,
          ).copyWith(top: AppSpacing.s16 + clearOfHeader),
          child: ServerIdentityScope(
            entry: entry,
            builder: (context, name, _) => _Pill(
              name: name,
              onTap: () =>
                  ref.read(accountHostProvider)?.switchTo(entry.account.origin),
            ),
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.name, required this.onTap});

  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final height = AppTouchTargets.of(context) ? 44.0 : 36.0;
    return Material(
      type: MaterialType.transparency,
      child: Semantics(
        button: true,
        liveRegion: true,
        label: 'In a call on $name. Return to it',
        excludeSemantics: true,
        onTap: onTap,
        child: GestureDetector(
          key: AccountCallPill.pillKey,
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Container(
              height: height,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s16),
              decoration: BoxDecoration(
                color: tokens.surfaceRaised,
                borderRadius: BorderRadius.circular(AppRadii.full),
                border: Border.all(color: tokens.borderStrong),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    AppIcons.startCall,
                    size: AppSizes.icon16,
                    color: tokens.status.online,
                  ),
                  const SizedBox(width: AppSpacing.s8),
                  Flexible(
                    child: Text(
                      'In a call on $name',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.ui.copyWith(color: tokens.textPrimary),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
