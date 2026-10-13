// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a server says about itself before anyone signs in: its build, the
/// protocol it speaks, what it can do, and the identity a client pins.
library;

import 'models_identity.dart';

/// What a server says about the safety tools slim-m's model depends on.
///
/// [unknown] is not [missing]. A server too old to advertise anything has not
/// said it has no report or block; accusing it of that would be a lie the
/// client made up, and the two states read differently to the user for that
/// reason.
enum SafetyTools { present, missing, unknown }

/// The two capabilities slim-m's safety model is made of. Reporting is how a
/// person reaches a human; blocking is what they can do without one.
const safetyCapabilities = <String>['report', 'block'];

/// The server's identity and negotiated protocol version.
class Version {
  const Version({
    required this.name,
    required this.version,
    required this.protocol,
    this.spaceName,
    this.pushEnabled,
    this.inviteRequired,
    this.claimed,
    this.gifSearchEnabled,
    this.iconUpdatedAt,
    this.linkPreviewsEnabled,
    this.screenShareMaxHeight,
    this.capabilities,
    this.identity,
    this.minClientVersion,
    this.buildId,
  });

  /// The product, always "slim-m"; [displayName] is what a member sees.
  final String name;
  final String version;
  final int protocol;

  /// The name an admin gave this Space; null from a server too old to have one.
  final String? spaceName;

  /// The Space's name, falling back to the product on an older server.
  String get displayName => spaceName ?? name;

  /// Whether the server can deliver push notifications at all. Null on
  /// servers too old to report it, which is "unknown", not "no": warning
  /// someone off a server that actually has push would be worse than
  /// staying quiet.
  final bool? pushEnabled;

  /// Whether creating an account here needs an invite code. Null on servers
  /// older than 0.14.2, which is "unknown": the sign-up screen stays quiet
  /// rather than promising either way.
  final bool? inviteRequired;

  /// Whether the first account has registered. False means the next
  /// registration claims the deployment as its admin. Null on a server older
  /// than this field, which is "unknown": the client treats it as claimed and
  /// opens on sign-in.
  final bool? claimed;

  /// Whether this deployment can search and attach GIFs at all. Null on a
  /// server too old to report it, and a client treats that the same as
  /// `false`: unlike push or invites there is nothing to warn anyone about
  /// either way, so the picker is simply absent - no button, no request.
  final bool? gifSearchEnabled;

  /// When the space icon was set, or null for none.
  final int? iconUpdatedAt;

  /// Whether this deployment unfurls pasted links into preview cards. Null on
  /// a server too old to report it, and a client treats that the same as
  /// `false`: the same "no button, no request" fallback [gifSearchEnabled]
  /// gets, for the same reason.
  final bool? linkPreviewsEnabled;

  /// The tallest resolution a screen share may publish at. Null on servers
  /// older than this field, which a client must treat as no ceiling: this
  /// rides on `/version`, unauthenticated, so every client can cap its own
  /// screen-share capture before starting a share, not only one that could
  /// reach the MANAGE_SERVER-gated `GET /space/screen-share`.
  final int? screenShareMaxHeight;

  /// The optional features the server serves, by name. Null on servers older
  /// than 0.17.0, which is "unknown", not "none".
  final List<String>? capabilities;

  /// The server's trust-on-first-use identity. Null on servers too old to
  /// report it, the same "unknown" treatment [pushEnabled] gets.
  final ServerIdentity? identity;

  /// The oldest client this deployment still serves, as `X.Y.Z`, or null for
  /// no floor - which is the default, and what every server older than this
  /// field reports by saying nothing. A client below it should stop and
  /// offer to update rather than run against a server it cannot speak to;
  /// see decision 0025.
  final String? minClientVersion;

  /// Short git SHA the server was built from. Null for a build without one or
  /// a server older than this field.
  final String? buildId;

  /// Whether this server offers reporting and blocking at all.
  SafetyTools get safetyTools => capabilities == null
      ? SafetyTools.unknown
      : missingSafetyTools.isEmpty
          ? SafetyTools.present
          : SafetyTools.missing;

  /// The names in [safetyCapabilities] this server does not advertise, in that
  /// list's order. Also empty on a server that advertised nothing at all, so
  /// read [safetyTools] before this to tell those apart.
  List<String> get missingSafetyTools {
    final advertised = capabilities;
    if (advertised == null) return const [];
    return safetyCapabilities
        .where((name) => !advertised.contains(name))
        .toList(growable: false);
  }

  factory Version.fromJson(Map<String, dynamic> json) => Version(
        name: json['name'] as String,
        spaceName: json['space_name'] as String?,
        version: json['version'] as String,
        protocol: json['protocol'] as int,
        pushEnabled: json['push_enabled'] as bool?,
        inviteRequired: json['invite_required'] as bool?,
        claimed: json['claimed'] as bool?,
        gifSearchEnabled: json['gif_search_enabled'] as bool?,
        iconUpdatedAt: json['icon_updated_at'] as int?,
        linkPreviewsEnabled: json['link_previews_enabled'] as bool?,
        screenShareMaxHeight: json['screen_share_max_height'] as int?,
        // A non-list here is a foreign or broken server, which is unknown
        // rather than a reason to crash sign-in.
        capabilities: switch (json['capabilities']) {
          final List<dynamic> names => names.whereType<String>().toList(
                growable: false,
              ),
          _ => null,
        },
        identity: json['identity'] == null
            ? null
            : ServerIdentity.fromJson(json['identity'] as Map<String, dynamic>),
        minClientVersion: json['min_client_version'] as String?,
        buildId: json['build_id'] as String?,
      );
}
