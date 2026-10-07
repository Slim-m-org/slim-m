// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Presence: what a caller may be told about another user, and the caller's
/// own visibility preference.
///
/// Split out of models.dart purely to stay under this repo's line budget; see
/// that file for how the pieces are recombined into one import.
library;

/// What a caller may be told about another user's live presence. Never
/// `hidden`: a user who chose that reads as [offline] to everyone but
/// themselves, and their true state when they ask about their own id.
enum PresenceState {
  online,
  away,
  dnd,
  offline;

  /// An unrecognised value reads as [offline]: the same reading a caller
  /// already gets for someone who chose to appear hidden, so a server
  /// growing this enum can never make an unfamiliar status read as more
  /// present, or more distinctive, than the one state this client is already
  /// built to under-report.
  static PresenceState parse(String value) => switch (value) {
        'online' => PresenceState.online,
        'away' => PresenceState.away,
        'dnd' => PresenceState.dnd,
        _ => PresenceState.offline,
      };
}

/// A kind of client a member is connected from, as the server classifies the
/// device each live socket signed in on.
enum PresenceDevice {
  mobile,
  desktop,
  web,
  unknown;

  /// A kind this client does not know reads as [unknown], which is never
  /// [mobile]: a newer server's new kind must not look like a phone.
  static PresenceDevice parse(Object? value) =>
      PresenceDevice.values.where((d) => d.name == value).firstOrNull ??
      PresenceDevice.unknown;

  /// The kinds in a frame's or response's `devices` list; empty when absent.
  static Set<PresenceDevice> parseAll(Object? json) => json is List<dynamic>
      ? {for (final value in json) PresenceDevice.parse(value)}
      : const {};
}

/// The caller's own visibility preference. [hidden] is the appear-offline
/// choice: the caller's own client still sees their true state; everyone
/// else sees [PresenceState.offline].
enum PresenceVisibility {
  online,
  away,
  dnd,
  hidden;

  String get wire => name;

  /// An unrecognised value reads as [hidden]. This is the caller's own
  /// choice echoed back, and defaulting toward a more public state on a
  /// value this client cannot decode risks telling someone they are visible
  /// when they are not - the one misreading this app must never produce.
  static PresenceVisibility parse(String value) => switch (value) {
        'online' => PresenceVisibility.online,
        'away' => PresenceVisibility.away,
        'dnd' => PresenceVisibility.dnd,
        _ => PresenceVisibility.hidden,
      };
}

/// What kind of thing a member is sharing.
enum ActivityKind {
  listening,
  playing;

  String get wire => name;

  /// Null for a kind this client does not know, so the activity is dropped
  /// rather than shown as something it is not.
  static ActivityKind? tryParse(Object? value) => switch (value) {
        'listening' => ActivityKind.listening,
        'playing' => ActivityKind.playing,
        _ => null,
      };
}

const _artPrefix = 'https://i.scdn.co/image/';
const _artIdLength = 40;

/// True only for a Spotify cover URL of the exact shape the server accepts
/// (decision 0056). Checked again before drawing, so a server that widened
/// the rule still could not make this client fetch another host.
bool isAllowedArtUrl(String url) {
  if (!url.startsWith(_artPrefix)) return false;
  final id = url.substring(_artPrefix.length);
  return id.length == _artIdLength && RegExp(r'^[0-9a-f]+$').hasMatch(id);
}

/// What a member is listening to or playing. Ephemeral: the server holds it
/// only for as long as their socket is open and tells only those who may see
/// their presence.
class PresenceActivity {
  const PresenceActivity({
    required this.kind,
    required this.title,
    this.subtitle,
    this.startedAt,
    this.source,
    String? artUrl,
  }) : _artUrl = artUrl;

  /// The most characters the server accepts in [title] or [subtitle].
  static const maxTextChars = 128;

  /// The most characters the server accepts in [source].
  static const maxSourceChars = 32;

  final ActivityKind kind;
  final String title;
  final String? subtitle;

  /// Epoch milliseconds the activity began, when the source knows.
  final int? startedAt;

  /// Which player reported it ("Spotify", "Firefox"), when it said.
  final String? source;

  final String? _artUrl;

  /// Spotify cover art; null for anything the server would refuse.
  String? get artUrl {
    final url = _artUrl;
    return url != null && isAllowedArtUrl(url) ? url : null;
  }

  /// Null when [json] is absent or unreadable.
  static PresenceActivity? tryFromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final kind = ActivityKind.tryParse(json['type']);
    final title = json['title'];
    if (kind == null || title is! String || title.isEmpty) return null;
    final subtitle = json['subtitle'];
    final startedAt = json['started_at'];
    final source = json['source'];
    final artUrl = json['art_url'];
    return PresenceActivity(
      kind: kind,
      title: title,
      subtitle: subtitle is String && subtitle.isNotEmpty ? subtitle : null,
      startedAt: startedAt is int ? startedAt : null,
      source: source is String && source.isNotEmpty ? source : null,
      artUrl: artUrl is String ? artUrl : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'type': kind.wire,
        'title': title,
        if (subtitle != null) 'subtitle': subtitle,
        if (startedAt != null) 'started_at': startedAt,
        if (source != null) 'source': source,
        if (artUrl != null) 'art_url': artUrl,
      };

  @override
  bool operator ==(Object other) =>
      other is PresenceActivity &&
      other.kind == kind &&
      other.title == title &&
      other.subtitle == subtitle &&
      other.startedAt == startedAt &&
      other.source == source &&
      other.artUrl == artUrl;

  @override
  int get hashCode =>
      Object.hash(kind, title, subtitle, startedAt, source, artUrl);
}

/// One user's presence, as told to the asking caller.
class PresenceStatus {
  const PresenceStatus({
    required this.userId,
    required this.status,
    this.activity,
    this.devices = const {},
  });

  final String userId;
  final PresenceState status;
  final PresenceActivity? activity;

  /// The kinds of client the member is connected from. Empty when offline or
  /// hidden from this caller, and from a server too old to say.
  final Set<PresenceDevice> devices;

  factory PresenceStatus.fromJson(Map<String, dynamic> json) => PresenceStatus(
        userId: json['user_id'] as String,
        status: PresenceState.parse(json['status'] as String),
        activity: PresenceActivity.tryFromJson(json['activity']),
        devices: PresenceDevice.parseAll(json['devices']),
      );
}
