// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A role's display colour: hashed from its id, not a stored property.
///
/// `AppBadge`'s own doc already flags that role data carries no colour
/// column in this app (`AppBadgeVariant.role` is styled from the accent for
/// every role alike); the roles pane's design wants a colour dot to tell
/// roles apart in the list at a glance, so this hashes one deterministically
/// the same way `AppAvatar` tints an avatar from an identity string, rather
/// than adding schema and API surface for a property nothing else asked
/// for.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart' show stableIndexFor;

/// A closed set distinct from `AppAvatar`'s own tint list, so a role dot and
/// a member avatar never read as the same kind of thing at a glance.
const List<Color> _roleTints = [
  Color(0xFFC9A227),
  Color(0xFF58B4D8),
  Color(0xFF7A8FA6),
  Color(0xFF8A6FA8),
  Color(0xFF6FA88A),
  Color(0xFFA87A6F),
];

/// Hashes [roleId] to one of [_roleTints]. `@everyone` and every ordinary
/// role are hashed the same way; nothing here treats either specially.
Color roleColor(String roleId) =>
    _roleTints[stableIndexFor(roleId, _roleTints.length)];
