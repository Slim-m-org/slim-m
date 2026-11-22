// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Shared room state a module keeps in a call or a channel (decision 0131).
///
/// [ModuleRoom.state] is whatever JSON the module answered, decoded; only the
/// module that wrote it knows its shape, so a slot reads it by its module id.
library;

/// One module's state in one room. [seq] counts the states the room has held.
class ModuleRoom {
  const ModuleRoom({
    required this.moduleId,
    required this.seq,
    required this.state,
    this.updatedAtMs = 0,
  });

  final String moduleId;
  final int seq;
  final Object? state;
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
      updatedAtMs: updated is int ? updated : 0,
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
    this.reason,
    this.error,
  });

  final bool applied;
  final int seq;
  final Object? state;
  final String? reason;
  final String? error;

  /// Whether the input ended the room.
  bool get ended => applied && seq == 0 && state == null;

  factory ModuleRoomInputResult.fromJson(Map<String, dynamic> json) =>
      ModuleRoomInputResult(
        applied: json['applied'] == true,
        seq: json['seq'] is int ? json['seq'] as int : 0,
        state: json['state'],
        reason: json['reason'] as String?,
        error: json['error'] as String?,
      );
}
