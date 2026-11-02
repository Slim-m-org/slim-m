// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The live quality chip on a share's control strip, and the pick it opens.
///
/// The chip reads what is arriving now; the menu under it is the Watching
/// quality setting, which is global, so it is headed that way instead of
/// looking like a choice for this one stream. Rule 2 of
/// docs/design/desktop-vs-mobile.md: picking one value for a control that
/// stays on screen, an anchored menu wide and a sheet compact.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../../widgets/context_menu_region.dart';
import '../providers/voice_settings_controller.dart';
import 'stream_quality_row.dart';
import 'video_quality_labels.dart';

class StreamQualityChip extends ConsumerStatefulWidget {
  const StreamQualityChip({
    super.key,
    required this.sampler,
    required this.identity,
    required this.onHold,
  });

  final CallStatsSampler sampler;
  final String identity;

  /// Keeps the strip up while the pick is open.
  final ValueChanged<bool> onHold;

  @override
  ConsumerState<StreamQualityChip> createState() => _StreamQualityChipState();
}

class _StreamQualityChipState extends ConsumerState<StreamQualityChip> {
  final _menu = GlobalKey<ContextMenuRegionState>();
  final _group = Object();

  List<Widget> _items(BuildContext context, VoidCallback close) {
    final current = ref.read(
      voiceSettingsControllerProvider.select((s) => s.receiveVideoQuality),
    );
    final notifier = ref.read(voiceSettingsControllerProvider.notifier);
    return [
      const AppMenuLabel('Watching quality (all streams)'),
      for (final quality in ReceiveVideoQuality.values)
        AppMenuItem(
          label: receiveVideoQualityLabel(quality),
          selected: quality == current,
          onTap: () {
            close();
            notifier.setReceiveVideoQuality(quality);
          },
        ),
    ];
  }

  @override
  Widget build(BuildContext context) => ContextMenuRegion(
    key: _menu,
    ownsFocusNode: false,
    enableLongPress: false,
    tapRegionGroupId: _group,
    onOpenChanged: widget.onHold,
    itemsBuilder: _items,
    child: TapRegion(
      groupId: _group,
      child: StreamQualityBuilder(
        sampler: widget.sampler,
        identity: widget.identity,
        source: CallStatsSource.screenShare,
        builder: (context, label) => AppButton(
          label: label ?? 'Quality',
          icon: AppIcons.requestLatency,
          size: AppButtonSize.sm,
          variant: AppButtonVariant.ghost,
          semanticLabel:
              'Receiving quality, ${label ?? 'measuring'}. Change watching quality',
          onPressed: () => _menu.currentState?.toggle(),
        ),
      ),
    ),
  );
}
