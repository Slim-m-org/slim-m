// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Acting on a conversation: picking messages to delete, dropping a file on the
/// channel, and the channel's own settings screen.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_app/src/features/channels/screens/channel_settings_screen.dart';
import 'package:slimm_app/src/features/messages/providers/message_selection.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/routing/modal_page.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_data/data.dart' show Channel;
import 'package:slimm_design_system/design_system.dart' show AppInput;

import '../ui_snapshot_support.dart';
import 'ui_review_conversation_and_search_data.dart';
import 'ui_review_conversation_and_search_router.dart';
import 'ui_review_conversation_and_search_support.dart';

/// Picks the messages the first (and second) argument names, as a long-press on a row would.
ReviewAct _selecting(List<String> ids, {bool confirm = false}) => (rig) async {
  final selection = rig.container.read(
    messageSelectionProvider('c-general').notifier,
  )..start(ids.first);
  for (final id in ids.skip(1)) {
    selection.toggle(id);
  }
  await rig.settle();
  if (confirm) await rig.tapText('Delete');
};

Future<void> _dropEvent(WidgetTester tester, String method, Object? args) =>
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'desktop_drop',
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
      (_) {},
    );

/// A file drag entering the middle of the channel pane, where the drop zone listens.
Future<void> _dragOver(ReviewRig rig) async {
  await _dropEvent(rig.tester, 'entered', [640.0, 400.0]);
  await rig.settle();
}

/// A folder dropped on the pane, which the composer refuses with a reason.
Future<void> _dropFolder(ReviewRig rig) async {
  await _dropEvent(rig.tester, 'entered', [640.0, 400.0]);
  await _dropEvent(rig.tester, 'performOperation_macos', [
    {'path': '/home/nick/Pictures/holiday', 'isDirectory': true},
  ]);
  await rig.settle();
}

const _general = Channel(
  id: 'c-general',
  name: 'general',
  kind: 'text',
  createdAt: 0,
  position: 0,
  topic: 'General chat for the whole Space - keep it friendly.',
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
);

const _directMessage = Channel(
  id: 'c-dm-ada',
  name: 'Ada Lovelace',
  kind: 'dm',
  createdAt: 0,
  position: 0,
  topic: '',
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
  dmParticipantId: 'user-ada',
);

/// The settings route with its own arguments, which the shared fixture hardwires to #general.
GoRouter _settingsRouter(Channel? channel, {bool cold = false}) => reviewRouter(
  cold ? Routes.channelSettings : '/channels/c-general',
  routes: [
    GoRoute(
      path: Routes.channelSettings,
      pageBuilder: (context, state) => modalPage(
        context,
        ChannelSettingsScreen(
          args: channel == null
              ? null
              : ChannelSettingsRouteArgs(channel: channel, wasOpen: false),
        ),
      ),
    ),
  ],
);

void _settings(
  String state, {
  required int permissions,
  Channel? channel = _general,
  bool cold = false,
  ReviewAct? act,
}) => reviewCase(
  'settings-channel',
  state: state,
  router: () => _settingsRouter(channel, cold: cold),
  pushRoute: cold ? null : Routes.channelSettings,
  permissions: permissions,
  act: act,
);

const _viewAndSend = Perm.viewChannel | Perm.sendMessages;

void main() {
  setUpAll(loadRealFonts);

  reviewCase(
    'msg-selection-mode',
    state: 'two-selected',
    messages: fullTranscript,
    act: _selecting(['m-33', 'm-34']),
  );
  reviewCase(
    'msg-selection-mode',
    state: 'none-selected',
    messages: fullTranscript,
    act: (rig) async {
      await _selecting(['m-33'])(rig);
      rig.container
          .read(messageSelectionProvider('c-general').notifier)
          .toggle('m-33');
    },
  );
  reviewCase(
    'msg-selection-mode',
    state: 'delete-confirm',
    messages: fullTranscript,
    act: _selecting(['m-33', 'm-34'], confirm: true),
  );

  reviewCase(
    'overlay-file-drop',
    state: 'channel-target',
    viewports: const [ReviewViewport.desktop],
    platform: TargetPlatform.linux,
    messages: fullTranscript,
    act: _dragOver,
  );
  reviewCase(
    'overlay-file-drop',
    state: 'refused',
    viewports: const [ReviewViewport.desktop],
    platform: TargetPlatform.linux,
    messages: fullTranscript,
    act: _dropFolder,
  );

  _settings('dm-or-group', permissions: -1, channel: _directMessage);
  _settings('roles-only', permissions: _viewAndSend | Perm.manageRoles);
  _settings('channels-only', permissions: _viewAndSend | Perm.manageChannels);
  _settings('no-access', permissions: _viewAndSend);
  _settings('cold-url', permissions: -1, channel: null, cold: true);
  _settings(
    'dirty',
    permissions: -1,
    act: (rig) => rig.typeInto(
      find.byWidgetPredicate(
        (w) => w is AppInput && w.semanticLabel == 'Channel name',
      ),
      'general-chat',
    ),
  );
}
