// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Data exports: a member's own data and a whole space, built in the background.
library;

/// Which archive a job builds.
enum ExportKind { member, space }

/// Where a job is. `expired` also covers a ready archive past its lifetime.
enum ExportStatus {
  queued,
  running,
  ready,
  failed,
  expired;

  /// Whether the job is still working.
  bool get isActive => this == queued || this == running;
}

class DataExport {
  const DataExport({
    required this.id,
    required this.kind,
    required this.status,
    required this.processed,
    required this.total,
    required this.createdAt,
    this.sizeBytes,
    this.error,
    this.finishedAt,
    this.expiresAt,
  });

  final String id;
  final ExportKind kind;
  final ExportStatus status;

  /// Messages and files written so far, and expected in all (zero until counted).
  final int processed;
  final int total;
  final int? sizeBytes;

  /// A short reason when [status] is [ExportStatus.failed].
  final String? error;
  final int createdAt;
  final int? finishedAt;

  /// When the archive is deleted, unix milliseconds.
  final int? expiresAt;

  /// How far along it is, 0 to 1, or null before the total is known.
  double? get fraction =>
      total > 0 ? (processed / total).clamp(0.0, 1.0).toDouble() : null;

  factory DataExport.fromJson(Map<String, dynamic> json) => DataExport(
        id: json['id'] as String,
        kind: json['kind'] == 'space' ? ExportKind.space : ExportKind.member,
        status: ExportStatus.values.firstWhere(
          (s) => s.name == json['status'],
          orElse: () => ExportStatus.failed,
        ),
        processed: json['processed'] as int,
        total: json['total'] as int,
        sizeBytes: json['size_bytes'] as int?,
        error: json['error'] as String?,
        createdAt: json['created_at'] as int,
        finishedAt: json['finished_at'] as int?,
        expiresAt: json['expires_at'] as int?,
      );
}
