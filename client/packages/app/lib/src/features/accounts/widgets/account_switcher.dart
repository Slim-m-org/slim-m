// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rail header's server switcher: tap the server's name to change server.
/// A menu on a wide window, a sheet on a compact one (desktop-vs-mobile rule 2).
/// See docs/decisions/0068-multiple-servers-in-one-app.md.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/anchored_menu.dart';
import '../../../widgets/animated_menu_portal.dart';
import '../providers/account_providers.dart';
import 'account_server_label.dart';
import 'account_unread_badge.dart';

/// Wraps the header's server identity. With no account host it is just [child].
class AccountSwitcherTrigger extends ConsumerStatefulWidget {
  const AccountSwitcherTrigger({super.key, required this.child});

  final Widget child;

  static const Key triggerKey = Key('account_switcher_trigger');

  @override
  ConsumerState<AccountSwitcherTrigger> createState() =>
      _AccountSwitcherTriggerState();
}

class _AccountSwitcherTriggerState
    extends ConsumerState<AccountSwitcherTrigger> {
  final _controller = AnimatedMenuController();

  void _open(BuildContext context) {
    if (MediaQuery.sizeOf(context).width < kCompactWidth) {
      unawaited(
        showAppSheet<void>(
          context,
          bare: true,
          builder: (sheetContext) => SafeArea(
            top: false,
            child: AccountSwitcherMenu(
              onDone: () => Navigator.of(sheetContext).pop(),
            ),
          ),
        ),
      );
    } else {
      _controller.toggle();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(accountHostProvider) == null) return widget.child;
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final elsewhere = ref.watch(
      accountsSnapshotProvider.select((s) => s.unreadElsewhere),
    );
    return AnchoredMenu(
      controller: _controller,
      targetAnchor: Alignment.bottomLeft,
      followerAnchor: Alignment.topLeft,
      menu: AccountSwitcherMenu(onDone: _controller.hide),
      child: Semantics(
        button: true,
        label: 'Switch server',
        excludeSemantics: true,
        onTap: () => _open(context),
        child: GestureDetector(
          key: AccountSwitcherTrigger.triggerKey,
          behavior: HitTestBehavior.opaque,
          onTap: () {
            AppHaptics.selection();
            _open(context);
          },
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(child: widget.child),
                if (elsewhere.any)
                  Padding(
                    padding: const EdgeInsets.only(right: AppSpacing.s4),
                    child: AccountUnreadBadge(unread: elsewhere),
                  ),
                Icon(
                  AppIcons.serverSwitcher,
                  size: AppSizes.icon16,
                  color: tokens.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The servers this device is signed into, and the ways to add or leave one.
class AccountSwitcherMenu extends ConsumerWidget {
  const AccountSwitcherMenu({super.key, required this.onDone});

  final VoidCallback onDone;

  static const Key addKey = Key('account_switcher_add');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final host = ref.watch(accountHostProvider);
    final snapshot = ref.watch(accountsSnapshotProvider);
    return AppSheetMenu(
      width: 300,
      children: [
        const Align(
          alignment: Alignment.centerLeft,
          child: AppMenuLabel('Servers'),
        ),
        for (final entry in snapshot.entries)
          _ServerRow(
            entry: entry,
            onSelect: () {
              onDone();
              unawaited(host?.switchTo(entry.account.origin));
            },
            onSignOut: () {
              onDone();
              unawaited(host?.signOut(entry.account.origin));
            },
          ),
        const AppMenuDivider(),
        AppMenuItem(
          key: addKey,
          label: 'Add a server',
          leading: AppIcons.add,
          onTap: () {
            onDone();
            unawaited(host?.beginAdd());
          },
        ),
      ],
    );
  }
}

class _ServerRow extends StatelessWidget {
  const _ServerRow({
    required this.entry,
    required this.onSelect,
    required this.onSignOut,
  });

  final AccountEntry entry;
  final VoidCallback onSelect;
  final VoidCallback onSignOut;

  String get _subtitle {
    if (!entry.signedIn) return 'Signed out';
    if (entry.inCall) return 'In a call';
    return entry.account.serverUrl.host;
  }

  @override
  Widget build(BuildContext context) {
    return ServerIdentityScope(
      entry: entry,
      builder: (context, name, iconUpdatedAt) => AppListRow(
        label: name,
        subtitle: _subtitle,
        selected: entry.active,
        stateDescription: entry.active ? 'Current server' : null,
        leading: ServerIconTile(
          name: name,
          iconUpdatedAt: iconUpdatedAt,
          size: AppSizes.icon20,
        ),
        trailing: entry.active
            ? null
            : AccountUnreadBadge(unread: entry.unread),
        trailingExtra: AppIconButton(
          icon: AppIcons.signOut,
          semanticLabel: entry.signedIn ? 'Sign out of $name' : 'Remove $name',
          size: AppIconButtonSize.sm,
          onPressed: onSignOut,
        ),
        onTap: onSelect,
      ),
    );
  }
}
