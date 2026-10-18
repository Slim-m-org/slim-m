// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The plain sentence for one audit-log row: what changed, named from the
/// local caches, then from the log itself once the thing is gone.
library;

import 'package:slimm_api/api.dart' as api;

/// Where a target's name comes from once the change itself carries none.
class AuditNames {
  const AuditNames({
    this.roles = const {},
    this.channels = const {},
    this.categories = const {},
    this.emoji = const {},
    this.users = const {},
    this.logged = const {},
  });

  final Map<String, String> roles;
  final Map<String, String> channels;
  final Map<String, String> categories;
  final Map<String, String> emoji;
  final Map<String, String> users;

  /// The newest name the loaded log recorded for each target id.
  final Map<String, String> logged;

  /// The names the loaded [changes] recorded, for targets since deleted.
  static Map<String, String> loggedNames(List<api.AdminChange> changes) {
    final names = <String, String>{};
    // Newest first, so reversing lets the newest entry for an id win.
    for (final change in changes.reversed) {
      final id = change.targetId;
      final name = change.name;
      if (id != null && name != null) names[id] = name;
    }
    return names;
  }
}

/// "renamed role Moderators", "deleted channel #general": the sentence that
/// follows the actor's name.
String describeAdminChange(api.AdminChange change, AuditNames names) =>
    _Describer(change, names).sentence();

/// "name, description" from a request's field names.
String _fieldList(List<String> fields) =>
    fields.map((f) => f.replaceAll('_', ' ')).join(', ');

String _humanise(String action) => action.replaceAll(RegExp(r'[._]'), ' ');

class _Describer {
  _Describer(this.change, this.names);

  final api.AdminChange change;
  final AuditNames names;

  String? get _target => change.targetId;

  String? _lookup(Map<String, String> cache, String? id) =>
      id == null ? null : cache[id] ?? names.logged[id];

  String? _name(Map<String, String> cache) =>
      change.name ?? _lookup(cache, _target);

  String _role([String? otherId]) {
    final name = otherId == null
        ? _name(names.roles)
        : _lookup(names.roles, otherId);
    return name == null ? 'a role' : 'role $name';
  }

  String _channel() {
    final name = _name(names.channels);
    return name == null ? 'a channel' : '#$name';
  }

  String _category() {
    final name = _name(names.categories);
    return name == null ? 'a category' : 'category $name';
  }

  String _emoji() {
    final name = _name(names.emoji);
    return name == null ? 'an emoji' : ':$name:';
  }

  String _user() {
    final id = _target;
    return (id == null ? null : names.users[id]) ?? 'a member';
  }

  String _module() {
    final id = _target;
    final plain = id != null && id.length <= 40 && !id.contains(' ');
    return plain ? 'module $id' : 'a module';
  }

  bool get _onlyName {
    final fields = change.fields;
    return fields.length == 1 && fields.first == 'name';
  }

  String _changed(String subject) {
    final fields = change.fields;
    return fields.isEmpty
        ? 'changed $subject'
        : 'changed $subject: ${_fieldList(fields)}';
  }

  String _update(String subject) =>
      _onlyName && change.name != null ? 'renamed $subject' : _changed(subject);

  String sentence() => switch (change.action) {
    'space.update' => _changed('space settings'),
    'space.join_gate' => 'changed who can join',
    'space.analytics' => 'changed usage analytics',
    'space.retention' => 'changed message retention',
    'space.canvas_cap' => 'changed the canvas limit',
    'space.screen_share' => 'changed the screen share limit',
    'space.attachment_limit' => 'changed the attachment size limit',
    'space.icon_set' => 'set the space icon',
    'space.icon_clear' => 'removed the space icon',
    'space.banner_set' => 'set the space banner',
    'space.banner_clear' => 'removed the space banner',
    'role.create' => 'created ${_role()}',
    'role.reorder' => 'reordered roles',
    'role.update' => _update(_role()),
    'role.delete' => 'deleted ${_role()}',
    'role.assign' => 'gave ${_role(change.param('role_id'))} to ${_user()}',
    'role.unassign' =>
      'removed ${_role(change.param('role_id'))} from ${_user()}',
    'role.module_grant' => 'granted a module permission to ${_role()}',
    'role.module_revoke' => 'revoked a module permission from ${_role()}',
    'channel.create' => 'created ${_channel()}',
    'channel.reorder' => 'reordered channels',
    'channel.update' => _update(_channel()),
    'channel.delete' => 'deleted ${_channel()}',
    'channel.retention' => 'changed retention on ${_channel()}',
    'channel.room' => 'changed room settings on ${_channel()}',
    'channel.overwrites' => 'changed permissions on ${_channel()}',
    'channel.overwrites_sync' =>
      'synced permissions on ${_channel()} with its category',
    'channel.overwrite_set' => 'set a permission override on ${_channel()}',
    'channel.overwrite_clear' =>
      'cleared a permission override on ${_channel()}',
    'category.create' => 'created ${_category()}',
    'category.update' => _update(_category()),
    'category.delete' => 'deleted ${_category()}',
    'category.overwrites' => 'changed permissions on ${_category()}',
    'invite.create' => 'created an invite',
    'invite.revoke' =>
      _target == null ? 'revoked an invite' : 'revoked invite $_target',
    'emoji.create' => 'added ${_emoji()}',
    'emoji.bulk_create' => 'added several emoji',
    'emoji.delete' => 'deleted ${_emoji()}',
    'module.install' => 'installed ${_module()}',
    'module.uninstall' => 'removed ${_module()}',
    'module.enable' => 'turned on ${_module()}',
    'module.disable' => 'turned off ${_module()}',
    'module.schedule_channel' => 'set the schedule channel for ${_module()}',
    'module_source.add' => 'added a module source',
    'module_source.remove' => 'removed a module source',
    _ => _humanise(change.action),
  };
}
