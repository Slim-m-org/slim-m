// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call stage's body: every share, camera and audio-only person placed by
/// [fitStage] in the box it is given, and animated to its new rect when the
/// window or the roster changes (decision 0114).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../layout/stage_content.dart';
import '../layout/stage_fit.dart';
import '../providers/voice_controller.dart';
import 'participant_tile_builder.dart';
import 'local_share_tile.dart';
import 'share_stage_grid.dart';
import 'stage_person_chip.dart';

const double stageGap = AppSpacing.s12;

class CallStageFitView extends StatefulWidget {
  const CallStageFitView({
    super.key,
    required this.participants,
    required this.shares,
    required this.focused,
    required this.directStage,
    required this.controller,
    required this.onOpenProfile,
    required this.onStopWatching,
    required this.onFocus,
    this.menuItemsBuilder,
  });

  final List<VoiceParticipant> participants;
  final List<VoiceParticipant> shares;

  /// The share the viewer pinned, if any.
  final String? focused;

  /// The viewer's own player, which takes the pinned place while they play directly.
  final Widget? directStage;
  final VoiceController controller;
  final void Function(BuildContext anchor, VoiceParticipant participant)
  onOpenProfile;
  final void Function(String identity) onStopWatching;
  final void Function(String? identity) onFocus;
  final List<Widget> Function(
    BuildContext,
    VoiceParticipant,
    VoidCallback, {
    bool withStreams,
  })?
  menuItemsBuilder;

  @override
  State<CallStageFitView> createState() => _CallStageFitViewState();
}

class _CallStageFitViewState extends State<CallStageFitView> {
  final List<String> _seen = [];
  String? _fitKey;
  StageFit? _fit;

  String? get _pinned {
    final ids = [for (final s in widget.shares) s.identity];
    _seen.removeWhere((id) => !ids.contains(id));
    // A batch of new shares at once ties on age; the roster's first of them wins.
    _seen.addAll(ids.where((id) => !_seen.contains(id)).toList().reversed);
    if (ids.contains(widget.focused)) return widget.focused;
    // The viewer's own share is a calm tile, so it only takes the pin when nothing else is shared.
    final remote = _seen.where(
      (id) => !widget.shares.any((s) => s.identity == id && s.isLocal),
    );
    if (remote.isNotEmpty) return remote.last;
    return _seen.isEmpty ? null : _seen.last;
  }

  StageFit _fitFor(Size box, StageContent content) {
    final key =
        '${box.width}x${box.height}|${content.people.length}|'
        '${[for (final i in content.items) '${i.id}@${i.aspect}']}';
    if (key != _fitKey) {
      _fitKey = key;
      _fit = fitStage(
        box: box,
        gap: stageGap,
        content: content.items,
        people: content.people.length,
      );
    }
    return _fit!;
  }

  @override
  Widget build(BuildContext context) {
    final content = buildStageContent(
      participants: widget.participants,
      shares: widget.shares,
      pinned: _pinned,
      directPlaying: widget.directStage != null,
    );
    final byId = {for (final p in widget.participants) p.identity: p};
    return LayoutBuilder(
      builder: (context, constraints) {
        final fit = _fitFor(constraints.biggest, content);
        final duration = AppMotion.reducedSize(context, AppMotion.base);
        Widget place(String key, Rect r, Widget child) => AnimatedPositioned(
          key: ValueKey(key),
          duration: duration,
          curve: AppMotion.entrance,
          left: r.left,
          top: r.top,
          width: r.width,
          height: r.height,
          child: child,
        );
        return Stack(
          clipBehavior: Clip.none,
          children: [
            for (final item in content.items)
              place(
                item.id,
                fit.items[item.id]!,
                _contentTile(context, item, byId, content),
              ),
            ..._peopleTiles(context, content, fit),
          ],
        );
      },
    );
  }

  /// Sized from the box it is in, which is mid-animation while a rect settles.
  Widget _animatedTile(VoiceParticipant person) => LayoutBuilder(
    builder: (context, box) => participantTile(
      context,
      person,
      widget.controller,
      widget.onOpenProfile,
      width: box.maxWidth,
      height: box.maxHeight,
      menuItemsBuilder: widget.menuItemsBuilder,
    ),
  );

  Widget _contentTile(
    BuildContext context,
    StageItem item,
    Map<String, VoiceParticipant> byId,
    StageContent content,
  ) {
    if (item.id == directStageId) return widget.directStage!;
    final isShare = item.kind == StageKind.share;
    final identity = item.id.substring(item.id.indexOf(':') + 1);
    final person = byId[identity];
    if (person == null) return const SizedBox.shrink();
    if (!isShare) {
      return _animatedTile(person);
    }
    if (person.isLocal) {
      return LocalShareTile(
        onStop: () => unawaited(widget.controller.share.setScreenShare(false)),
      );
    }
    final pinned = identity == content.pinnedIdentity;
    final tile = shareStageTile(
      context,
      person,
      widget.controller,
      onStopWatching: () => widget.onStopWatching(identity),
      onFocus: pinned ? null : () => widget.onFocus(identity),
      personItems: _personItems(context, person),
    );
    final entering = AppFadeIn(offset: 0, child: tile);
    if (pinned) return entering;
    return GestureDetector(
      onTap: () => widget.onFocus(identity),
      child: entering,
    );
  }

  /// A sharer has no tile of their own (decision 0114), so their share's menu carries their voice rows too.
  List<Widget> Function(VoidCallback close)? _personItems(
    BuildContext context,
    VoiceParticipant person,
  ) {
    final build = widget.menuItemsBuilder;
    if (build == null) return null;
    return (close) => build(context, person, close, withStreams: false);
  }

  List<Widget> _peopleTiles(
    BuildContext context,
    StageContent content,
    StageFit fit,
  ) {
    final duration = AppMotion.reducedSize(context, AppMotion.base);
    final people = content.people;
    return [
      for (var i = 0; i < fit.people.length; i++)
        AnimatedPositioned(
          key: ValueKey(
            fit.peopleOverflow > 0 && i == fit.people.length - 1
                ? 'person:overflow'
                : 'person:${people[i].identity}',
          ),
          duration: duration,
          curve: AppMotion.entrance,
          left: fit.people[i].left,
          top: fit.people[i].top,
          width: fit.people[i].width,
          height: fit.people[i].height,
          child: _personTile(context, people, fit, i),
        ),
    ];
  }

  Widget _personTile(
    BuildContext context,
    List<VoiceParticipant> people,
    StageFit fit,
    int i,
  ) {
    if (!fit.peopleCollapsed) {
      return _animatedTile(people[i]);
    }
    if (fit.peopleOverflow > 0 && i == fit.people.length - 1) {
      return StagePersonChip.overflow(count: fit.peopleOverflow);
    }
    return StagePersonChip(
      participant: people[i],
      onTap: (anchor) => widget.onOpenProfile(anchor, people[i]),
    );
  }
}
