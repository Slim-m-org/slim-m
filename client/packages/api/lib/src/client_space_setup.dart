// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'client.dart';

/// What the server estimates it can carry, from `GET /space/setup`.
class SpaceCapacityEstimate {
  const SpaceCapacityEstimate({
    required this.binding,
    required this.connectionLimit,
    required this.membersMin,
    required this.membersMax,
    this.voiceMin,
    this.voiceMax,
  });

  /// The first thing to run out: `connections`, `memory` or `processor`.
  final String binding;
  final int connectionLimit;
  final int membersMin;
  final int membersMax;

  /// People in one call if LiveKit shares this machine; null when voice is off.
  final int? voiceMin;
  final int? voiceMax;

  factory SpaceCapacityEstimate.fromJson(Map<String, dynamic> json) =>
      SpaceCapacityEstimate(
        binding: json['binding'] as String,
        connectionLimit: json['connection_limit'] as int,
        membersMin: json['members_min'] as int,
        membersMax: json['members_max'] as int,
        voiceMin: json['voice_min'] as int?,
        voiceMax: json['voice_max'] as int?,
      );
}

/// The machine the server runs on.
class SpaceCapacity {
  const SpaceCapacity({
    required this.cores,
    required this.voiceConfigured,
    required this.estimate,
    this.memoryTotalBytes,
    this.memoryLimitBytes,
    this.diskFreeBytes,
    this.diskTotalBytes,
  });

  final int cores;
  final bool voiceConfigured;
  final SpaceCapacityEstimate estimate;
  final int? memoryTotalBytes;

  /// The container's memory limit, null when the server is not limited.
  final int? memoryLimitBytes;
  final int? diskFreeBytes;
  final int? diskTotalBytes;

  /// The memory the server can actually use: the limit when it has one.
  int? get usableMemoryBytes {
    final total = memoryTotalBytes;
    final limit = memoryLimitBytes;
    if (total != null && limit != null) return limit < total ? limit : total;
    return limit ?? total;
  }

  factory SpaceCapacity.fromJson(Map<String, dynamic> json) => SpaceCapacity(
        cores: json['cores'] as int,
        voiceConfigured: json['voice_configured'] as bool,
        estimate: SpaceCapacityEstimate.fromJson(
          json['estimate'] as Map<String, dynamic>,
        ),
        memoryTotalBytes: json['memory_total_bytes'] as int?,
        memoryLimitBytes: json['memory_limit_bytes'] as int?,
        diskFreeBytes: json['disk_free_bytes'] as int?,
        diskTotalBytes: json['disk_total_bytes'] as int?,
      );
}

/// The first-run setup state and the machine report, `GET /space/setup`.
class SpaceSetup {
  const SpaceSetup({
    required this.claimedByMe,
    required this.completed,
    required this.capacity,
  });

  /// Whether the caller is the admin whose registration claimed the space.
  final bool claimedByMe;
  final bool completed;
  final SpaceCapacity capacity;

  /// Offered once, to the claiming admin, until finished or dismissed.
  bool get owed => claimedByMe && !completed;

  factory SpaceSetup.fromJson(Map<String, dynamic> json) => SpaceSetup(
        claimedByMe: json['claimed_by_me'] as bool,
        completed: json['completed'] as bool,
        capacity: SpaceCapacity.fromJson(
          json['capacity'] as Map<String, dynamic>,
        ),
      );
}

extension SlimmApiSpaceSetup on SlimmApi {
  /// Requires MANAGE_SERVER.
  Future<SpaceSetup> spaceSetup() async {
    final json = await _send('GET', '/space/setup');
    return SpaceSetup.fromJson(json as Map<String, dynamic>);
  }

  /// Only the admin who claimed the space may close its setup.
  Future<void> completeSpaceSetup() =>
      _send('POST', '/space/setup/complete', expectNoContent: true);
}
