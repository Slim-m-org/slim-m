// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Shared room state a module keeps in a call or a channel (decision 0131).
///
/// [ModuleRoom.state] is whatever JSON the module answered, decoded; only the
/// module that wrote it knows its shape, so a slot reads it by its module id.
library;

import 'dart:convert';

/// The `scene/1` a module drew from its state (decision 0132), as text for the
/// scene parser, or `null` when it drew none.
String? roomSceneText(Object? json) => json is Map ? jsonEncode(json) : null;

/// One module's state in one room. [seq] counts the states the room has held.
class ModuleRoom {
  const ModuleRoom({
    required this.moduleId,
    required this.seq,
    required this.state,
    this.scene,
    this.updatedAtMs = 0,
  });

  final String moduleId;
  final int seq;
  final Object? state;

  /// See [roomSceneText].
  final String? scene;
  final int updatedAtMs;

  /// A list entry, or `null` when it is not one.
  static ModuleRoom? tryParse(Object? json) {
    if (json is! Map) return null;
    final moduleId = json['module_id'];
    final seq = json['seq'];
    if (moduleId is! String || seq is! int) return null;
    final updated = json['updated_at_ms'];
    return ModuleRoom(
      moduleId: moduleId,
      seq: seq,
      state: json['state'],
      scene: roomSceneText(json['scene']),
      updatedAtMs: updated is int ? updated : 0,
    );
  }
}

/// A module that offers a scene on a call's stage (decision 0132).
class ModuleCallScene {
  const ModuleCallScene({required this.moduleId, required this.title});

  final String moduleId;
  final String title;

  static ModuleCallScene? tryParse(Object? json) {
    if (json is! Map) return null;
    final moduleId = json['module_id'];
    final title = json['title'];
    if (moduleId is! String || title is! String) return null;
    return ModuleCallScene(moduleId: moduleId, title: title);
  }
}

/// Every module's room in one channel, and the call scenes on offer there.
class ModuleRooms {
  const ModuleRooms({this.rooms = const [], this.callScenes = const []});

  final List<ModuleRoom> rooms;

  /// Empty in a text channel, and from an older server.
  final List<ModuleCallScene> callScenes;

  factory ModuleRooms.fromJson(Object? json) {
    List<T> read<T>(Object? raw, T? Function(Object?) parse) => raw is List
        ? raw.map(parse).whereType<T>().toList(growable: false)
        : const [];
    final map = json is Map ? json : const <String, Object?>{};
    return ModuleRooms(
      rooms: read(map['rooms'], ModuleRoom.tryParse),
      callScenes: read(map['call_scenes'], ModuleCallScene.tryParse),
    );
  }
}

/// What one input did: [applied] with the room's [state] at [seq] now, or
/// refused ([reason], from the module) or failed ([error]) with the room as it was.
class ModuleRoomInputResult {
  const ModuleRoomInputResult({
    required this.applied,
    required this.seq,
    required this.state,
    this.scene,
    this.reason,
    this.error,
  });

  final bool applied;
  final int seq;
  final Object? state;

  /// See [roomSceneText].
  final String? scene;
  final String? reason;
  final String? error;

  /// Whether the input ended the room.
  bool get ended => applied && seq == 0 && state == null;

  factory ModuleRoomInputResult.fromJson(Map<String, dynamic> json) =>
      ModuleRoomInputResult(
        applied: json['applied'] == true,
        seq: json['seq'] is int ? json['seq'] as int : 0,
        state: json['state'],
        scene: roomSceneText(json['scene']),
        reason: json['reason'] as String?,
        error: json['error'] as String?,
      );
}
