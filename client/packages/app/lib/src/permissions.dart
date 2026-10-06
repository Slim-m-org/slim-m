// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A client-side mirror of `crates/slimm-server/src/permissions.rs`.
///
/// Every bit here must match the server's `Permissions` constants exactly:
/// this is what `Me.permissions` and `Role.permissions` are bitmasks of. Used
/// only to decide what to show; every write is still re-authorized
/// server-side from scratch regardless of what a caller can see.
library;

import 'action_labels.dart';

abstract final class Perm {
  static const int administrator = 1 << 0;
  static const int viewChannel = 1 << 1;
  static const int sendMessages = 1 << 2;
  static const int manageMessages = 1 << 3;
  static const int manageChannels = 1 << 4;
  static const int manageRoles = 1 << 5;
  static const int kickMembers = 1 << 6;
  static const int banMembers = 1 << 7;
  static const int createInvite = 1 << 8;
  static const int addReactions = 1 << 9;
  static const int attachFiles = 1 << 10;
  static const int connect = 1 << 11;
  static const int speak = 1 << 12;
  static const int useCanvas = 1 << 13;
  static const int manageCanvas = 1 << 14;
  static const int manageServer = 1 << 15;

  /// Whether `@everyone`/`@here` actually wake anyone the caller mentions
  /// with them, rather than sitting as plain text; see
  /// `crates/slimm-server/src/permissions.rs`'s own doc on this bit.
  static const int mentionEveryone = 1 << 16;

  /// Run a fenced code block through this deployment's configured code
  /// runner, when one is configured at all (decision 0026). Defaults to
  /// nobody on every fresh deployment and DM; see the server's own doc on
  /// this bit for why.
  static const int runCode = 1 << 17;

  /// Read moderation history without `manageMessages`'s write power.
  static const int viewModerationHistory = 1 << 18;

  /// Every bit that has a name, in the fixed order the editor lists them.
  static const List<(int bit, String label)> editable = [
    (administrator, 'Administrator'),
    (viewChannel, 'View channels'),
    (sendMessages, 'Send messages'),
    (manageMessages, 'Manage messages'),
    (manageChannels, 'Manage channels'),
    (manageRoles, 'Manage roles'),
    (kickMembers, ActionLabels.removeMembers),
    (banMembers, 'Ban members'),
    (createInvite, 'Create invites'),
    (addReactions, 'Add reactions'),
    (attachFiles, 'Attach files'),
    (connect, 'Join voice channels'),
    (speak, 'Speak in voice channels'),
    (useCanvas, 'Use the voice canvas'),
    (manageCanvas, 'Manage the voice canvas'),
    (manageServer, 'Manage Space settings'),
    (mentionEveryone, 'Mention @everyone and @here'),
    (runCode, 'Run code blocks'),
    (viewModerationHistory, 'View moderation history'),
  ];

  /// [groups] flattened, in the same order - the channel permissions grid's
  /// row list, since a grid has no room for group headers of its own and
  /// [administrator] never applies to a per-channel overwrite: the server's
  /// evaluator returns every permission for it before any overwrite is read.
  static final List<PermSpec> gridRows = List.unmodifiable([
    for (final group in groups) ...group.permissions,
  ]);

  /// Every grantable permission but [administrator], grouped and described
  /// the way the roles pane's Permissions tab lists them. Administrator is
  /// its own special row above every group, not a member of one, since it
  /// is not "one permission among others" - it grants all of them.
  static const List<PermGroup> groups = [
    PermGroup('Messages', [
      PermSpec(
        sendMessages,
        'Send messages',
        'Post in text channels this role can see.',
      ),
      PermSpec(
        manageMessages,
        'Manage messages',
        "Delete and pin other people's messages.",
      ),
      PermSpec(attachFiles, 'Attach files', 'Upload images and files.'),
      PermSpec(addReactions, 'Add reactions', 'React to messages with emoji.'),
    ]),
    PermGroup('Moderation', [
      PermSpec(
        manageRoles,
        'Manage roles',
        'Edit and assign roles below this one.',
        elevated: true,
      ),
      PermSpec(
        kickMembers,
        ActionLabels.removeMembers,
        'Remove someone; they can rejoin with an invite.',
        elevated: true,
      ),
      PermSpec(
        banMembers,
        'Ban members',
        'Remove someone and block them from rejoining.',
        elevated: true,
      ),
      PermSpec(
        viewModerationHistory,
        'View moderation history',
        'Read past moderation actions, without the power to take new ones.',
      ),
    ]),
    PermGroup('Voice & canvas', [
      PermSpec(connect, 'Join voice channels', 'Connect to a voice channel.'),
      PermSpec(
        speak,
        'Speak in voice channels',
        'Transmit audio after joining.',
      ),
      PermSpec(
        useCanvas,
        'Use the voice canvas',
        'Draw and place objects during a call.',
      ),
      PermSpec(
        manageCanvas,
        'Manage the voice canvas',
        'Clear or reset the canvas for everyone in the call.',
      ),
    ]),
    PermGroup('Channels & invites', [
      PermSpec(
        viewChannel,
        'View channels',
        'See a channel this role is not otherwise denied.',
      ),
      PermSpec(
        manageChannels,
        'Manage channels',
        'Create, rename, reorder and delete channels.',
        elevated: true,
      ),
      PermSpec(
        createInvite,
        'Create invites',
        'Generate invite links to this Space.',
      ),
    ]),
    PermGroup('Space', [
      PermSpec(
        manageServer,
        'Manage Space settings',
        'Change deployment-wide settings for everyone.',
        elevated: true,
      ),
      PermSpec(
        mentionEveryone,
        'Mention @everyone and @here',
        'Wake every member with a mention.',
        elevated: true,
      ),
    ]),
    PermGroup('Extensions', [
      PermSpec(
        runCode,
        'Run code blocks',
        "Execute a fenced code block through this deployment's configured runner.",
      ),
    ]),
  ];
}

/// One permission's display metadata: the label and one-line description the
/// roles pane's Permissions tab and the channel permissions grid both read
/// off, plus whether it is tagged `elevated` - a permission that can act on
/// other members or the whole deployment, called out the same way the design
/// review does, not a bit the server treats specially.
class PermSpec {
  const PermSpec(
    this.bit,
    this.label,
    this.description, {
    this.elevated = false,
  });

  final int bit;
  final String label;
  final String description;
  final bool elevated;
}

/// A named run of [PermSpec]s, the roles pane's group headers
/// (`MESSAGES`, `MODERATION`, ...).
class PermGroup {
  const PermGroup(this.title, this.permissions);

  final String title;
  final List<PermSpec> permissions;
}

/// Whether a raw permission bitmask contains every bit in [required].
/// Mirrors the server's own `contains`: [administrator] is not special-cased
/// here, matching `Me.permissions` and `Role.permissions`, which already
/// carry it as an ordinary bit a caller can check for directly.
extension PermissionCheck on int {
  bool hasPermission(int required) => (this & required) == required;
}
