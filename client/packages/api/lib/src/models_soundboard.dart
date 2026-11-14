// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Soundboard clips: the Space's short audio clips (decision 0118).
library;

/// One soundboard clip. The audio is fetched separately through
/// [SlimmApiSoundboard.fetchSoundClipAudio]; the bytes are content-addressed
/// and never change under an id.
class SoundClip {
  const SoundClip({
    required this.id,
    required this.name,
    required this.durationMs,
    required this.uploaderId,
    required this.createdAt,
  });

  final String id;
  final String name;

  /// The length the server read from the bytes at upload.
  final int durationMs;

  /// Null once the uploader's account has been deleted.
  final String? uploaderId;

  /// When it was added, unix milliseconds.
  final int createdAt;

  factory SoundClip.fromJson(Map<String, dynamic> json) => SoundClip(
        id: json['id'] as String,
        name: json['name'] as String,
        durationMs: json['duration_ms'] as int,
        uploaderId: json['uploader_id'] as String?,
        createdAt: json['created_at'] as int,
      );
}
