// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Invite a friend": makes a single-use 24 hour invite and hands its link to the share sheet or clipboard, from the Space menu and the member list header.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../api_failure.dart';
import '../../../invite_link.dart';
import '../../../permissions.dart';
import '../../../providers/admin_providers.dart';
import '../../../providers/providers.dart';
import '../../../providers/toasts.dart';
import '../../channels/widgets/channel_rail_frame.dart' show serverInfoProvider;

const _inviteLifetime = Duration(hours: 24);

/// Hands an invite link to the person: the OS share sheet or the clipboard.
abstract class InviteSharer {
  /// True where an OS share sheet exists.
  bool get canShare;

  Future<void> share(String link);
}

class PlatformInviteSharer implements InviteSharer {
  const PlatformInviteSharer();

  @override
  bool get canShare =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  Future<void> share(String link) async {
    await SharePlus.instance.share(ShareParams(text: link));
  }
}

final inviteSharerProvider = Provider<InviteSharer>(
  (ref) => const PlatformInviteSharer(),
);

/// Whether to offer "Invite a friend": the caller holds CREATE_INVITE, or the
/// Space lets every member invite. The server decides again on the write.
bool watchCanInviteFriend(WidgetRef ref) {
  if (ref.watch(myPermissionsProvider).hasPermission(Perm.createInvite)) {
    return true;
  }
  return ref.watch(serverInfoProvider).valueOrNull?.membersCanInvite ?? false;
}

/// Makes the invite and shares it. A failure opens a sheet with a retry, since
/// an error never rides on a toast.
Future<void> inviteAFriend(BuildContext context) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final String link;
  // A member's invite already defaults to one use and a day on the server's clock, so a skewed device clock cannot get it refused.
  final isMember = !container
      .read(myPermissionsProvider)
      .hasPermission(Perm.createInvite);
  try {
    final invite = await container
        .read(apiProvider)
        .createInvite(
          maxUses: 1,
          expiresAt: isMember
              ? null
              : DateTime.now().add(_inviteLifetime).millisecondsSinceEpoch,
        );
    link = buildInviteLink(
      server: container.read(serverUrlProvider),
      code: invite.code,
    );
  } on api.ApiException catch (e, stack) {
    api.reportFailure(api.LogTag.ui, 'create the invite', e, stack);
    if (!context.mounted) return;
    await showAppSheet<void>(
      context,
      builder: (sheetContext) => _InviteFailedSheet(
        message: describeApiFailure('create the invite', e),
        onRetry: () {
          Navigator.of(sheetContext).pop();
          inviteAFriend(context);
        },
      ),
    );
    return;
  }
  final sharer = container.read(inviteSharerProvider);
  if (sharer.canShare) {
    await sharer.share(link);
    return;
  }
  await Clipboard.setData(ClipboardData(text: link));
  container
      .read(toastsProvider.notifier)
      .show(
        'Invite link copied. It works once, for 24 hours.',
        severity: AppToastSeverity.success,
      );
}

class _InviteFailedSheet extends StatelessWidget {
  const _InviteFailedSheet({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(AppSpacing.s16),
    child: AppErrorState(message: message, onRetry: onRetry),
  );
}
