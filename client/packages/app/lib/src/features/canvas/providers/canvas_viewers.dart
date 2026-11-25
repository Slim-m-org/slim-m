// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Who has each board open: one roster for the whole deployment, read when first needed and kept current by frames.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/live_events.dart';
import '../../../providers/providers.dart';
import '../../../providers/server_info.dart';
import '../../../providers/sync_controller.dart';
import '../../members/providers/blocks_controller.dart';
import '../../members/providers/user_profiles.dart';

/// The roster as last read, and whether a read has landed at all.
class CanvasViewersState {
  const CanvasViewersState({this.loaded = false, this.byChannel = const {}});

  /// False until the first answer; an arrival is only announced once it is true.
  final bool loaded;

  /// Each board's viewers, earliest arrival first. A board nobody is on has no entry.
  final Map<String, List<api.CanvasViewer>> byChannel;

  /// The people on [channelId]'s board, none when nobody is.
  List<api.CanvasViewer> of(String channelId) =>
      byChannel[channelId] ?? const [];
}

class CanvasViewersController extends Notifier<CanvasViewersState> {
  bool _disposed = false;
  int _generation = 0;

  /// Frames that arrived while a read was in flight, replayed over its answer.
  List<api.CanvasViewerChanged>? _inFlight;

  @override
  CanvasViewersState build() {
    ref.watch(sessionProvider);
    _disposed = false;
    final events = ref.read(liveEventsProvider).listen(_onEvent);
    ref.onDispose(() {
      _disposed = true;
      unawaited(events.cancel());
    });
    ref.listen<SyncStatus>(syncControllerProvider, (previous, next) {
      if (next == SyncStatus.live && previous != SyncStatus.live) {
        unawaited(load());
      }
    });
    if (ref.read(syncControllerProvider) == SyncStatus.live) {
      Future<void>.microtask(load);
    }
    return const CanvasViewersState();
  }

  /// Reads the roster again; a server without the capability leaves it empty.
  Future<void> load() async {
    final generation = ++_generation;
    _inFlight = [];
    try {
      final info = await ref.read(serverInfoProvider.future);
      if (!info.supportsCanvasViewers) {
        if (!_disposed && generation == _generation) {
          state = const CanvasViewersState(loaded: true);
        }
        return;
      }
      final boards = await ref.read(apiProvider).canvasViewers();
      if (_disposed || generation != _generation) return;
      var next = {for (final b in boards) b.channelId: b.viewers};
      for (final frame in _inFlight ?? const <api.CanvasViewerChanged>[]) {
        next = _applied(next, frame);
      }
      state = CanvasViewersState(loaded: true, byChannel: next);
    } on Object catch (error, stack) {
      api.reportFailure(
        api.LogTag.ui,
        'read who is viewing boards',
        error,
        stack,
      );
    } finally {
      if (generation == _generation) _inFlight = null;
    }
  }

  void _onEvent(api.ServerEvent event) {
    switch (event) {
      case api.CanvasViewerChanged():
        _inFlight?.add(event);
        state = CanvasViewersState(
          loaded: state.loaded,
          byChannel: _applied(state.byChannel, event),
        );
      case api.ChannelUpdated(:final channel) when !channel.hasCanvas:
        _drop(channel.id);
      case api.ChannelDeleted(:final channelId):
        _drop(channelId);
      default:
    }
  }

  void _drop(String channelId) {
    if (!state.byChannel.containsKey(channelId)) return;
    state = CanvasViewersState(
      loaded: state.loaded,
      byChannel: {...state.byChannel}..remove(channelId),
    );
  }
}

Map<String, List<api.CanvasViewer>> _applied(
  Map<String, List<api.CanvasViewer>> byChannel,
  api.CanvasViewerChanged frame,
) {
  final current = byChannel[frame.channelId] ?? const <api.CanvasViewer>[];
  final present = current.any((v) => v.userId == frame.userId);
  if (frame.viewing == present) return byChannel;
  final List<api.CanvasViewer> next;
  if (frame.viewing) {
    final latest = current.fold(0, (m, v) => v.since > m ? v.since : m);
    final since = latest == 0
        ? DateTime.now().millisecondsSinceEpoch
        : latest + 1;
    next = [...current, api.CanvasViewer(userId: frame.userId, since: since)];
  } else {
    next = [
      for (final v in current)
        if (v.userId != frame.userId) v,
    ];
  }
  final updated = {...byChannel};
  if (next.isEmpty) {
    updated.remove(frame.channelId);
  } else {
    updated[frame.channelId] = next;
  }
  return updated;
}

/// The roster for the signed-in account; rebuilt, and so emptied, when the session changes.
final canvasViewersProvider =
    NotifierProvider<CanvasViewersController, CanvasViewersState>(
      CanvasViewersController.new,
    );

/// Who has the board of [channelId] open, minus anyone this device blocks; this device's own entry is included.
final canvasChannelViewersProvider =
    Provider.family<List<api.CanvasViewer>, String?>((ref, channelId) {
      if (channelId == null) return const [];
      final viewers = ref.watch(
        canvasViewersProvider.select((s) => s.byChannel[channelId]),
      );
      if (viewers == null) return const [];
      final blocks = ref.watch(blocksProvider);
      return [
        for (final v in viewers)
          if (!blocks.contains(v.userId)) v,
      ];
    });

/// One person with a board open, named for a list.
class CanvasViewerPerson {
  const CanvasViewerPerson({required this.id, required this.name});

  final String id;
  final String name;

  @override
  bool operator ==(Object other) =>
      other is CanvasViewerPerson && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

/// The viewers of [channelId] in arrival order, with the names the profile cache holds; unknown ones are asked for.
final canvasViewerPeopleProvider =
    Provider.family<List<CanvasViewerPerson>, String?>((ref, channelId) {
      if (channelId == null) return const [];
      final viewers = ref.watch(canvasChannelViewersProvider(channelId));
      final profiles = ref.watch(batchProfilesControllerProvider);
      final unknown = [
        for (final v in viewers)
          if (!profiles.containsKey(v.userId)) v.userId,
      ];
      if (unknown.isNotEmpty) {
        final resolver = ref.read(batchProfilesControllerProvider.notifier);
        Future<void>.microtask(() => resolver.resolve(unknown));
      }
      return [
        for (final v in viewers)
          CanvasViewerPerson(
            id: v.userId,
            name: profiles.containsKey(v.userId)
                ? profiles[v.userId]?.displayName ?? 'Deleted user'
                : 'Someone',
          ),
      ];
    });

/// Somebody who just opened the board of [channelId], for the one announcer to say aloud.
class CanvasViewerArrival {
  const CanvasViewerArrival(this.channelId, this.userId);

  final String channelId;
  final String userId;
}

/// The latest arrival; the people host writes it and the activity announcer reads it.
final canvasViewerArrivalProvider = StateProvider<CanvasViewerArrival?>(
  (ref) => null,
);
