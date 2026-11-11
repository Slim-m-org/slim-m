// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `/debug-logs`: client debug logs sent to the admins.
library;

/// What the server answers a submission with.
class SubmittedDebugLog {
  const SubmittedDebugLog({required this.id, required this.createdAt});

  final int id;
  final int createdAt;

  factory SubmittedDebugLog.fromJson(Map<String, dynamic> json) =>
      SubmittedDebugLog(
        id: json['id'] as int,
        createdAt: json['created_at'] as int,
      );
}

/// One submitted log without its text. [id] is the paging cursor.
class DebugLogEntry {
  const DebugLogEntry({
    required this.id,
    required this.userId,
    required this.username,
    required this.displayName,
    required this.note,
    required this.appVersion,
    required this.platform,
    required this.sizeBytes,
    required this.createdAt,
  });

  final int id;
  final String userId;
  final String username;
  final String displayName;
  final String note;
  final String appVersion;
  final String platform;
  final int sizeBytes;
  final int createdAt;

  factory DebugLogEntry.fromJson(Map<String, dynamic> json) => DebugLogEntry(
        id: json['id'] as int,
        userId: json['user_id'] as String,
        username: json['username'] as String,
        displayName: json['display_name'] as String,
        note: json['note'] as String,
        appVersion: json['app_version'] as String,
        platform: json['platform'] as String,
        sizeBytes: json['size_bytes'] as int,
        createdAt: json['created_at'] as int,
      );
}

/// A submitted log with its text.
class DebugLogDownload {
  const DebugLogDownload({required this.entry, required this.log});

  final DebugLogEntry entry;
  final String log;

  factory DebugLogDownload.fromJson(Map<String, dynamic> json) =>
      DebugLogDownload(
        entry: DebugLogEntry.fromJson(json),
        log: json['log'] as String,
      );
}
