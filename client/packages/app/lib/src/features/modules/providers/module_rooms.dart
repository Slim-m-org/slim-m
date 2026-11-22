// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The shared room state modules keep in a call or channel (decision 0131),
/// for a slot to render from. The route gives every module's state, the
/// `module.room` frame keeps each current, and a reconnect reads it again,
/// since a frame missed while offline would leave a stale board up.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/live_events.dart';
import '../../../providers/providers.dart';
import '../../../providers/sync_controller.dart';

/// Every module's room state in one channel, by module id.
class ModuleRoomsModel {
  const ModuleRoomsModel({
    this.rooms = const {},
    this.callScenes = const [],
    this.notices = const {},
    this.sending = const {},
  });

  final Map<String, api.ModuleRoom> rooms;

  /// The modules that offer a scene on this call's stage (decision 0133).
  final List<api.ModuleCallScene> callScenes;

  /// Why a module last refused or failed this person's input, until their next one.
  final Map<String, String> notices;

  /// Modules this person has an input on its way to.
  final Set<String> sending;

  api.ModuleRoom? room(String moduleId) => rooms[moduleId];

  ModuleRoomsModel copyWith({
    Map<String, api.ModuleRoom>? rooms,
    List<api.ModuleCallScene>? callScenes,
    Map<String, String>? notices,
    Set<String>? sending,
  }) => ModuleRoomsModel(
    rooms: rooms ?? this.rooms,
    callScenes: callScenes ?? this.callScenes,
    notices: notices ?? this.notices,
    sending: sending ?? this.sending,
  );
}

class ModuleRoomsController
    extends AutoDisposeFamilyNotifier<ModuleRoomsModel, String> {
  late String channelId;
  bool _disposed = false;

  /// Bumped by every read and every frame, so a read that left before a newer frame is dropped.
  int _version = 0;

  api.SlimmApi get _api => ref.read(apiProvider);

  @override
  ModuleRoomsModel build(String arg) {
    channelId = arg;
    final events = ref.read(liveEventsProvider).listen(_onEvent);
    ref.onDispose(() {
      _disposed = true;
      unawaited(events.cancel());
    });
    ref.listen(syncControllerProvider, (previous, next) {
      if (next == SyncStatus.live && previous != SyncStatus.live) {
        unawaited(refresh());
      }
    });
    unawaited(Future<void>.microtask(refresh));
    return const ModuleRoomsModel();
  }

  void _onEvent(api.ServerEvent event) {
    if (event is! api.ModuleRoomChanged || event.channelId != channelId) {
      return;
    }
    _version++;
    if (event.state == null) {
      _forget(event.moduleId);
      return;
    }
    _hold(
      api.ModuleRoom(
        moduleId: event.moduleId,
        seq: event.seq,
        state: event.state,
        scene: event.scene,
      ),
    );
  }

  /// Keeps [room] unless a newer state of it is already held.
  void _hold(api.ModuleRoom room) {
    final held = state.rooms[room.moduleId];
    if (held != null && held.seq >= room.seq) return;
    state = state.copyWith(rooms: {...state.rooms, room.moduleId: room});
  }

  void _forget(String moduleId) {
    if (!state.rooms.containsKey(moduleId)) return;
    state = state.copyWith(rooms: {...state.rooms}..remove(moduleId));
  }

  /// Reads every room again; a server without room state reads as none.
  Future<void> refresh() async {
    final version = ++_version;
    api.ModuleRooms rooms;
    try {
      rooms = await _api.moduleRooms(channelId);
    } on api.ApiException catch (error, stack) {
      api.AppLog.swallowed(
        api.LogTag.data,
        'Module rooms are not available for this channel',
        error,
        stack,
      );
      rooms = const api.ModuleRooms();
    }
    if (_disposed || version != _version) return;
    state = state.copyWith(
      rooms: {for (final r in rooms.rooms) r.moduleId: r},
      callScenes: rooms.callScenes,
    );
  }

  /// Sends [input] to [moduleId]'s room here. The answer is the module's;
  /// `null` when the server refused to send it, with the reason in [ModuleRoomsModel.notices].
  Future<api.ModuleRoomInputResult?> send(String moduleId, String input) async {
    state = state.copyWith(
      sending: {...state.sending, moduleId},
      notices: {...state.notices}..remove(moduleId),
    );
    try {
      final result = await _api.sendModuleRoomInput(channelId, moduleId, input);
      if (!_disposed) _settle(moduleId, result);
      return result;
    } on api.ApiException catch (error) {
      if (!_disposed) _settle(moduleId, null, notice: error.message);
      return null;
    }
  }

  void _settle(
    String moduleId,
    api.ModuleRoomInputResult? result, {
    String? notice,
  }) {
    final why = notice ?? result?.reason ?? result?.error;
    state = state.copyWith(
      sending: {...state.sending}..remove(moduleId),
      notices: why == null ? null : {...state.notices, moduleId: why},
    );
    if (result == null || !result.applied) return;
    _version++;
    if (result.ended) {
      _forget(moduleId);
    } else {
      _hold(
        api.ModuleRoom(
          moduleId: moduleId,
          seq: result.seq,
          state: result.state,
          scene: result.scene,
        ),
      );
    }
  }
}

/// [channelId]'s module rooms, kept current while anything watches them.
final moduleRoomsProvider = NotifierProvider.autoDispose
    .family<ModuleRoomsController, ModuleRoomsModel, String>(
      ModuleRoomsController.new,
    );
