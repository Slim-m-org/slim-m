// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Shared fixtures for the three suites that pump a [MessageRow]: the row's
/// own rendering, its context menu, and its inline edit field.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it. It
/// exists because the row takes thirteen required callbacks and every one of
/// those suites needs the same message, the same all-denied action set and the
/// same provider-backed harness around it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_app/src/features/messages/widgets/message_context_menu.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

Message message({
  String id = 'm1',
  String? authorId = 'author-1',
  String? authorDisplayName = 'Priya',
  int createdAt = 1700000000000,
  int? editedAt,
  bool pending = false,
  bool failed = false,
  String? failureReason,
  String content = 'hello there',
}) => Message(
  id: id,
  channelId: 'c1',
  authorId: authorId,
  authorDisplayName: authorDisplayName,
  seq: 5,
  content: content,
  createdAt: createdAt,
  editedAt: editedAt,
  pending: pending,
  failed: failed,
  failureReason: failureReason,
);

void noop() {}

/// Every item hidden. Most tests care about nothing the context menu does, so
/// they pass this unchanged; the context menu suite builds its own with just
/// the flags it needs.
const noActions = MessageActions(
  canReply: false,
  onReply: noop,
  canEdit: false,
  onEdit: noop,
  canDelete: false,
  onDelete: noop,
  canManagePins: false,
  pinned: false,
  onTogglePin: noop,
  canReport: false,
  onReport: noop,
  canBlockAuthor: false,
  onBlockAuthor: noop,
  canOpenThread: false,
  onOpenThread: noop,
  canCopyLink: false,
  onCopyLink: noop,
  canForward: false,
  onForward: noop,
  canSave: true,
  onSave: noop,
);

/// The leading avatar is provider-backed (it resolves the author's own
/// avatar), so every row needs a ProviderScope even when a test cares about
/// nothing avatar-related; the default, unauthenticated apiProvider fails
/// fast on that lookup and the row falls back to initials, same as a real
/// signed-out state would.
///
/// [platform] defaults to null, which leaves `ThemeData`'s own default in
/// place (`TargetPlatform.android` under `flutter_test`) - already a soft
/// keyboard, so most callers exercise the phone path without asking for it.
/// A test asserting the hardware-keyboard path passes a desktop platform
/// explicitly, the way `composer_harness.dart` already does.
///
/// [overrides] is passed straight to the [ProviderScope]: empty by default,
/// for the one suite here (the time-format row) that needs a deterministic
/// answer rather than whatever the test binding's own platform reports.
Widget harness(
  Widget child, {
  TargetPlatform? platform,
  List<Override> overrides = const [],
}) => ProviderScope(
  overrides: overrides,
  child: MaterialApp(
    theme: platform == null
        ? buildTheme(Brightness.light, AppTokens.light)
        : buildTheme(
            Brightness.light,
            AppTokens.light,
          ).copyWith(platform: platform),
    home: Scaffold(body: child),
  ),
);
