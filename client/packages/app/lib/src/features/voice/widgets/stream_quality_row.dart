// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A quiet, read-only menu row saying what resolution and frame rate a watched
/// stream or camera is arriving at.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

/// Shows the received quality of [identity]'s [source], live while the menu is open.
class StreamQualityRow extends StatefulWidget {
  const StreamQualityRow({
    super.key,
    required this.sampler,
    required this.identity,
    required this.source,
  });

  final CallStatsSampler sampler;
  final String identity;
  final CallStatsSource source;

  @override
  State<StreamQualityRow> createState() => _StreamQualityRowState();
}

class _StreamQualityRowState extends State<StreamQualityRow> {
  StreamSubscription<CallStatsSnapshot>? _sub;
  String? _label;

  @override
  void initState() {
    super.initState();
    _label = _labelFrom(widget.sampler.latest);
    _sub = widget.sampler.snapshots.listen((snapshot) {
      final label = _labelFrom(snapshot);
      if (label != _label) setState(() => _label = label);
    });
  }

  String? _labelFrom(CallStatsSnapshot snapshot) {
    final key = receivedStatsKey(widget.identity, widget.source);
    return streamQualityLabel(snapshot.where((s) => s.key == key).firstOrNull);
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final touch = AppTouchTargets.of(context);
    final style = (touch ? AppText.body : AppText.ui).copyWith(
      color: tokens.textSecondary,
    );
    final value = _label ?? 'Measuring';
    return Semantics(
      label: 'Receiving quality, $value',
      container: true,
      excludeSemantics: true,
      child: Container(
        height: touch ? AppSizes.rowTouchMenu : AppSizes.controlMd,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          spacing: touch ? AppSpacing.s12 : AppSpacing.s8,
          children: [
            Icon(
              AppIcons.requestLatency,
              size: AppSizes.icon16,
              color: tokens.textSecondary,
            ),
            Expanded(
              child: Text(
                'Quality',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
            Text(value, style: style),
          ],
        ),
      ),
    );
  }
}
