// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "View server as this role" (decision 0124): which role the shell is showing the server as.
///
/// Held in memory only. Nothing here is written to the local store or to any real channel state.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/providers.dart';

/// One preview: the role it is for, the server's answer, and the channel opened in it.
class RolePreviewSession {
  const RolePreviewSession({
    required this.roleId,
    required this.roleName,
    this.preview = const AsyncLoading(),
    this.openChannelId,
  });

  final String roleId;
  final String roleName;
  final AsyncValue<api.RolePreview> preview;

  /// The channel whose summary shows, or null for none yet.
  final String? openChannelId;

  api.RolePreviewChannel? get openChannel {
    final id = openChannelId;
    if (id == null) return null;
    return preview.valueOrNull?.channels.where((c) => c.id == id).firstOrNull;
  }

  RolePreviewSession copyWith({
    AsyncValue<api.RolePreview>? preview,
    String? Function()? openChannelId,
  }) => RolePreviewSession(
    roleId: roleId,
    roleName: roleName,
    preview: preview ?? this.preview,
    openChannelId: openChannelId == null ? this.openChannelId : openChannelId(),
  );
}

/// Null while the shell shows the viewer's own server.
final rolePreviewProvider =
    NotifierProvider<RolePreviewController, RolePreviewSession?>(
      RolePreviewController.new,
    );

class RolePreviewController extends Notifier<RolePreviewSession?> {
  @override
  RolePreviewSession? build() => null;

  /// Starts showing the server as [role], loading its structure from the server.
  Future<void> enter(api.Role role) async {
    state = RolePreviewSession(roleId: role.id, roleName: role.name);
    await _load(role.id);
  }

  Future<void> retry() async {
    final session = state;
    if (session == null) return;
    state = session.copyWith(preview: const AsyncLoading());
    await _load(session.roleId);
  }

  Future<void> _load(String roleId) async {
    final AsyncValue<api.RolePreview> result = await AsyncValue.guard(
      () => ref.read(apiProvider).previewRole(roleId),
    );
    final session = state;
    // An exit, or a second role, while this was in flight wins.
    if (session == null || session.roleId != roleId) return;
    state = session.copyWith(preview: result);
  }

  void open(String channelId) =>
      state = state?.copyWith(openChannelId: () => channelId);

  /// Back to the channel list, on a phone where the summary replaced it.
  void close() => state = state?.copyWith(openChannelId: () => null);

  void exit() => state = null;
}
