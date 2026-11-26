// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call bar's screen share control: start from the rail, and while
/// sharing a menu to switch source or stop, through the call screen's own flow.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import '../../../widgets/context_menu_region.dart';
import '../../../widgets/control_options_menu.dart';
import '../../../widgets/control_swatch_row.dart' show ControlOptionEntry;
import '../../../widgets/shortcut_label.dart';
import '../../voice/providers/voice_controller.dart';
import '../../voice/providers/voice_flags.dart';
import '../../voice/widgets/call_device_options.dart' show callMenuWidth;
import '../../voice/widgets/call_share_flow.dart';
import '../../voice/widgets/share_options_menu.dart';

/// Screen share for the call [voice] describes.
///
/// [ownAccount] is false for a call another community holds: the flow reads the
/// on-screen account's saved quality, so that call can be stopped from here but
/// not started or switched.
class RailCallShareButton extends ConsumerStatefulWidget {
  const RailCallShareButton({
    super.key,
    required this.voice,
    required this.controller,
    this.ownAccount = true,
  });

  final VoiceFlags voice;
  final VoiceController controller;
  final bool ownAccount;

  @override
  ConsumerState<RailCallShareButton> createState() =>
      _RailCallShareButtonState();
}

class _RailCallShareButtonState extends ConsumerState<RailCallShareButton> {
  late final _flow = CallShareFlow(
    ref: ref,
    controller: () => widget.controller,
    voice: () => widget.voice,
    mounted: () => mounted,
    changed: setState,
  );

  /// Whether the menu was open as this press began, which the press itself closes.
  bool _menuWasOpen = false;

  void _stop() => unawaited(widget.controller.share.setScreenShare(false));

  List<ControlOptionEntry> _options(BuildContext context) {
    if (!widget.ownAccount) {
      if (!widget.voice.screenSharing) return const [];
      return [
        ControlOption(
          label: 'Stop sharing',
          icon: AppIcons.screenShareStop,
          tone: AppMenuItemTone.danger,
          onSelected: _stop,
        ),
      ];
    }
    return shareMenuEntries(
      ref,
      voice: widget.voice,
      controller: widget.controller,
      current: _flow.lastSource,
      actions: ShareMenuActions(
        onStop: () => _flow.toggle(context),
        onChangeSource: () => _flow.changeSource(context),
        onPickSource: (source) => _flow.pick(context, source),
      ),
    );
  }

  void _press(BuildContext context) {
    final voice = widget.voice;
    if (voice.screenSharing && !voice.awaitingBroadcast) {
      final menu = context.findAncestorStateOfType<ContextMenuRegionState>();
      if (!_menuWasOpen) menu?.open();
      return;
    }
    if (widget.ownAccount) {
      _flow.toggle(context);
    } else {
      _stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final voice = widget.voice;
    if (!widget.ownAccount &&
        !voice.screenSharing &&
        !voice.awaitingBroadcast) {
      return const SizedBox.shrink();
    }
    final sharing = voice.screenSharing;
    final pending = voice.awaitingBroadcast;
    final shortcut = shortcutSuffix(AppAction.toggleShareCall);
    final label = pending
        ? 'Cancel screen share'
        : sharing
        ? 'Screen share options'
        : 'Share a screen';
    final tooltip = pending
        ? 'Waiting for you to start the broadcast. Tap to cancel.'
        : sharing
        ? 'You are sharing your screen. Options'
        : 'Share a screen$shortcut';
    return ControlOptionsMenu(
      showCaret: false,
      optionsLabel: 'Screen share options',
      menuWidth: callMenuWidth,
      options: _options(context),
      child: KeyedSubtree(
        key: _flow.buttonKey,
        child: Builder(
          builder: (context) => Listener(
            onPointerDown: (_) => _menuWasOpen =
                context
                    .findAncestorStateOfType<ContextMenuRegionState>()
                    ?.isOpen ??
                false,
            child: AppIconButton(
              icon: AppIcons.screenShare,
              semanticLabel: label,
              tooltip: tooltip,
              excludeTooltipFromSemantics: true,
              active: sharing && !pending,
              onPressed: () => _press(context),
            ),
          ),
        ),
      ),
    );
  }
}
