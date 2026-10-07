// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every overlay the app can open, keyed by name, with the fixtures each one
/// needs and the one-route router that mounts them the way the real shell
/// does. Shared by the overlay snapshot test (does it fit its viewport?) and
/// the overlay semantics gate (can a screen reader reach everything on it?),
/// so a new sheet registered here is checked both ways at once.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/screens/admin/overwrite_target_picker_sheets.dart';
import 'package:slimm_app/src/screens/admin/role_create_sheet.dart';
import 'package:slimm_app/src/whats_new/whats_new_content.dart';
import 'package:slimm_app/src/widgets/avatar_crop_sheet.dart';
import 'package:slimm_app/src/widgets/camera_source_sheet.dart';
import 'package:slimm_app/src/widgets/command_palette.dart';
import 'package:slimm_app/src/widgets/composer_extras.dart';
import 'package:slimm_app/src/widgets/confirm_dialog.dart';
import 'package:slimm_app/src/widgets/create_channel_sheet.dart';
import 'package:slimm_app/src/widgets/emoji_picker.dart';
import 'package:slimm_app/src/widgets/member_profile.dart';
import 'package:slimm_app/src/widgets/pinned_messages_sheet.dart';
import 'package:slimm_app/src/widgets/poll_composer_sheet.dart';
import 'package:slimm_app/src/widgets/report_dialog.dart';
import 'package:slimm_app/src/widgets/screen_source_sheet.dart';
import 'package:slimm_app/src/widgets/whats_new_sheet.dart';
import 'package:slimm_data/data.dart' show Channel;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart' show CameraDevice, ScreenShareSource;

/// A 1x1 PNG, the same fixture `avatar_crop_sheet_test.dart` uses: all the
/// sheet needs to lay itself out.
final _png = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, //
  0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, //
  0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00, //
  0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xDD, 0x8D, //
  0xB0, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, //
  0x44, 0xAE, 0x42, 0x60, 0x82, //
]);

/// One row's worth of `channel_management_test.dart`'s own construction: the
/// manage sheet needs the local drift row, not the wire `api.Channel`.
final _localChannel = Channel(
  id: 'c-general',
  name: 'general',
  kind: 'text',
  createdAt: 0,
  position: 0,
  topic: 'General chat for the whole Space.',
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
);

const _adaProfile = api.UserProfile(
  id: 'user-ada',
  username: 'ada',
  displayName: 'Ada Lovelace',
  createdAt: 0,
);

/// Two entries, the same as `camera_source_sheet_test.dart`'s own fixture:
/// enough to show the picker choosing between more than one device.
const _cameraDevices = [
  CameraDevice(id: 'cam-0', label: 'FaceTime HD Camera'),
  CameraDevice(id: 'cam-1', label: 'Logitech BRIO'),
];

const _screenSources = [
  ScreenShareSource(id: 'screen-0', name: 'Screen 1'),
  ScreenShareSource(id: 'screen-1', name: 'Screen 2'),
];

/// Every overlay under review, keyed by name; each opens itself given a
/// mounted [BuildContext] and [WidgetRef].
final overlays = <String, FutureOr<void> Function(BuildContext, WidgetRef)>{
  'confirm-dialog': (context, ref) => confirmDangerousAction(
    context,
    title: 'Delete this account?',
    message:
        'Your devices, read state, and blocks are erased, and the username '
        'becomes available again.\n\nThis cannot be undone.',
    confirmLabel: 'Delete permanently',
    cancelLabel: 'Keep my account',
  ),
  'report-dialog': (context, ref) =>
      promptReportReason(context, subjectLabel: 'this message'),
  'create-channel-sheet': (context, ref) =>
      showCreateChannelSheet(context, initialKind: 'text'),
  'pinned-messages-sheet': (context, ref) =>
      showPinnedMessagesSheet(context, 'c-general'),
  'poll-composer-sheet': (context, ref) =>
      showPollComposerSheet(context, 'c-general'),
  'create-role-sheet': (context, ref) => showCreateRoleSheet(context),
  'avatar-crop-sheet': (context, ref) => showAvatarCropSheet(context, _png),
  'whats-new-sheet': (context, ref) =>
      showWhatsNewSheet(context, whatsNewEntries),
  'member-profile-popover': (context, ref) =>
      showMemberProfile(context, profile: _adaProfile),
  'command-palette': (context, ref) => openCommandPalette(context),
  'composer-actions-sheet': (context, ref) => showComposerActionsSheet(
    context,
    onPhotoLibrary: () {},
    onBrowseFiles: () {},
    canPasteImage: Future.value(false),
    onPasteImage: () {},
    onPoll: () {},
    onCode: () {},
  ),
  'camera-source-sheet': (context, ref) =>
      showCameraDeviceSheet(context, _cameraDevices),
  'screen-source-sheet': (context, ref) =>
      showScreenSourceSheet(context, _screenSources),
  'emoji-picker-sheet': (context, ref) =>
      showEmojiPickerSheet(context, onSelect: (_) {}),
  'space-emoji-sheet': (context, ref) =>
      showSpaceEmojiSheet(context, onSelect: (_) {}),
  // The three channel permissions grid picker sheets, spot-checked before.
  'channel-picker-sheet': (context, ref) => showAppSheet<Channel>(
    context,
    builder: (context) => ChannelPickerSheet(channels: [_localChannel]),
  ),
  'role-picker-sheet': (context, ref) => showAppSheet<api.Role>(
    context,
    builder: (context) => const RolePickerSheet(),
  ),
  'member-picker-sheet': (context, ref) => showAppSheet<api.UserProfile>(
    context,
    builder: (context) => const MemberPickerSheet(),
  ),
};

/// The two shipped shapes an overlay must work in: a wide desktop window,
/// where a sheet is a dialog, and a phone, where it is a bottom sheet.
const overlayViewports = <String, Size>{
  'desktop': Size(1400, 880),
  'phone': Size(390, 844),
};

/// The label of the one control on the route beneath an overlay, so a test
/// walking the tree can tell the opener apart from the overlay's own content.
const overlayOpenerLabel = 'open overlay';

/// A single route so `GoRouterState.of` and `selectedChannelId` (the pinned
/// messages sheet and the command palette both read the current channel)
/// resolve the same way they would inside the real shell. [open] runs with a
/// real [WidgetRef] straight from [Consumer]'s own builder, never a stand-in.
GoRouter overlayRouter(FutureOr<void> Function(BuildContext, WidgetRef) open) =>
    GoRouter(
      initialLocation: '/channels/c-general',
      routes: [
        GoRoute(
          path: '/channels/:channelId',
          builder: (context, state) => Scaffold(
            body: Consumer(
              builder: (context, ref, _) => Center(
                child: TextButton(
                  onPressed: () => open(context, ref),
                  child: const Text(overlayOpenerLabel),
                ),
              ),
            ),
          ),
        ),
      ],
    );
