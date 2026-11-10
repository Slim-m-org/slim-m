// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The first half of "Share to" when several servers are signed in: which
/// one the share goes to. Each server has its own conversations, so this has
/// to come before the destination list.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../routing/routes.dart';
import '../../accounts/providers/account_providers.dart';
import '../../accounts/widgets/account_server_label.dart';
import '../providers/incoming_share.dart';
import '../providers/share_intake.dart';
import 'share_summary.dart';

/// The host, with its port when it has one, so two servers on one machine read apart.
String _hostOf(Uri url) => url.hasPort ? '${url.host}:${url.port}' : url.host;

class ShareServerStep extends ConsumerWidget {
  const ShareServerStep({super.key, required this.share});

  final IncomingShare share;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = [
      for (final entry in ref.watch(accountsSnapshotProvider).entries)
        if (entry.signedIn) entry,
    ];
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.s16),
      children: [
        ShareSummary(share: share),
        const SizedBox(height: AppSpacing.s16),
        const AppMenuLabel('Servers'),
        for (final entry in entries)
          ServerIdentityScope(
            entry: entry,
            builder: (context, name, iconUpdatedAt) => AppListRow(
              label: name,
              subtitle: _hostOf(entry.account.serverUrl),
              leading: ServerIconTile(
                name: name,
                iconUpdatedAt: iconUpdatedAt,
                size: AppSizes.icon24,
              ),
              onTap: () {
                // The share moved to another container; this one's router must not stay on the picker.
                if (chooseShareServer(ref, entry.account.origin)) {
                  context.go(Routes.channels);
                }
              },
            ),
          ),
      ],
    );
  }
}
