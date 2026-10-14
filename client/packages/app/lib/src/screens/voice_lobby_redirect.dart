// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What opening a lobby voice channel shows (decision 0065): the call is not
/// in the lobby itself, so this gets the caller's own room and moves there,
/// whatever path arrived here.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' show SlimmApiVoiceRooms;
import 'package:slimm_design_system/design_system.dart';

import '../providers/providers.dart';
import '../routing/routes.dart';
import '../widgets/run_guarded.dart';
import 'voice_join_preview.dart' show VoiceConnecting;

class VoiceLobbyRedirect extends ConsumerStatefulWidget {
  const VoiceLobbyRedirect({required this.lobbyId, super.key});

  final String lobbyId;

  @override
  ConsumerState<VoiceLobbyRedirect> createState() => _VoiceLobbyRedirectState();
}

class _VoiceLobbyRedirectState extends ConsumerState<VoiceLobbyRedirect>
    with GuardedActionState<VoiceLobbyRedirect> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  @override
  void didUpdateWidget(covariant VoiceLobbyRedirect oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lobbyId != widget.lobbyId) _open();
  }

  Future<void> _open() async {
    String? roomId;
    await guard(
      whatFailed: 'open your room',
      action: () async {
        final room = await ref.read(apiProvider).openVoiceRoom(widget.lobbyId);
        // Stored before moving, so the room is in the rail before its live event lands.
        final store = await ref.read(storeProvider.future);
        await store.upsertChannels([room]);
        roomId = room.id;
      },
    );
    final target = roomId;
    if (target != null && mounted) context.go(Routes.channel(target));
  }

  @override
  Widget build(BuildContext context) {
    final error = actionError;
    if (error == null) return const VoiceConnecting();
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s24),
        child: AppErrorState(message: error, onRetry: _open),
      ),
    );
  }
}
