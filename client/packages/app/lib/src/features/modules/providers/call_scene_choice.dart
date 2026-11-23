// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which module's call scene this viewer has on the call's stage (decision
/// 0133). A scene that anyone in the call started shows for everyone; closing
/// it hides it for this viewer only, until they open it again.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../voice/providers/voice_flags.dart';
import 'module_rooms.dart';

/// What this viewer opened and closed in one call.
class CallSceneChoice {
  const CallSceneChoice({this.opened, this.closed = const {}});

  final String? opened;
  final Set<String> closed;
}

class CallSceneChoiceController
    extends FamilyNotifier<CallSceneChoice, String> {
  @override
  CallSceneChoice build(String arg) {
    // The choice is for one call; the next one in this channel starts clean.
    ref.listen(voiceFlagsProvider.select((flags) => flags.channelId), (
      previous,
      next,
    ) {
      if (previous == arg && next != arg) state = const CallSceneChoice();
    });
    return const CallSceneChoice();
  }

  void open(String moduleId) => state = CallSceneChoice(
    opened: moduleId,
    closed: {...state.closed}..remove(moduleId),
  );

  void close(String moduleId) => state = CallSceneChoice(
    opened: state.opened == moduleId ? null : state.opened,
    closed: {...state.closed, moduleId},
  );
}

/// [channelId]'s call: the viewer's choice of call scene.
final callSceneChoiceProvider =
    NotifierProvider.family<CallSceneChoiceController, CallSceneChoice, String>(
      CallSceneChoiceController.new,
    );

/// The call scene on this viewer's stage: the one they opened, else the first
/// one somebody started that they did not close.
api.ModuleCallScene? callSceneOnStage(
  ModuleRoomsModel rooms,
  CallSceneChoice choice,
) {
  bool shown(api.ModuleCallScene s) => !choice.closed.contains(s.moduleId);
  final offered = rooms.callScenes.where(shown);
  for (final scene in offered) {
    if (scene.moduleId == choice.opened) return scene;
  }
  for (final scene in offered) {
    if (rooms.room(scene.moduleId)?.scene != null) return scene;
  }
  return null;
}
