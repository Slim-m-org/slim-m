// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The participant context menu of a call, wired once for every place the
/// canvas lists a person: the participants sheet and the dock's roster.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../../widgets/context_menu_region.dart';
import '../../voice/widgets/call_participant_tiles.dart'
    show kParticipantMenuWidth;
import '../../voice/widgets/participant_call_menu.dart';

/// Opens the same menu a call tile has, on right-click, long-press or [open]; [builder] gets a null `open` when the participant has nothing to offer.
class CanvasParticipantMenu extends ConsumerStatefulWidget {
  const CanvasParticipantMenu({
    super.key,
    required this.participant,
    required this.builder,
    this.opensAbove = false,
  });

  final VoiceParticipant participant;
  final Widget Function(BuildContext context, VoidCallback? open) builder;

  /// For a trigger pinned to the bottom edge, where a menu below would not fit.
  final bool opensAbove;

  @override
  ConsumerState<CanvasParticipantMenu> createState() =>
      _CanvasParticipantMenuState();
}

class _CanvasParticipantMenuState extends ConsumerState<CanvasParticipantMenu> {
  final _region = GlobalKey<ContextMenuRegionState>();

  List<Widget> _items(BuildContext context, VoidCallback close) =>
      participantCallMenuItems(
        context,
        ref,
        participant: widget.participant,
        close: close,
        withFullscreen: false,
      );

  @override
  Widget build(BuildContext context) {
    final hasMenu = _items(context, () {}).isNotEmpty;
    return ContextMenuRegion(
      key: _region,
      ownsFocusNode: false,
      opensAbove: widget.opensAbove,
      menuWidth: kParticipantMenuWidth,
      itemsBuilder: _items,
      child: widget.builder(
        context,
        hasMenu ? () => _region.currentState?.open() : null,
      ),
    );
  }
}
