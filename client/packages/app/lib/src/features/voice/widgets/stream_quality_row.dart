// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A quiet, read-only menu row saying what resolution and frame rate a watched
/// stream or camera is arriving at.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

/// Rebuilds [builder] with the received quality label of [identity]'s [source],
/// listening to the sampler, which is what starts it sampling, for as long as it is mounted.
class StreamQualityBuilder extends StatefulWidget {
  const StreamQualityBuilder({
    super.key,
    required this.sampler,
    required this.identity,
    required this.source,
    required this.builder,
  });

  final CallStatsSampler sampler;
  final String identity;
  final CallStatsSource source;

  /// [label] is null until a first sample lands.
  final Widget Function(BuildContext context, String? label) builder;

  @override
  State<StreamQualityBuilder> createState() => _StreamQualityBuilderState();
}

class _StreamQualityBuilderState extends State<StreamQualityBuilder> {
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
  Widget build(BuildContext context) => widget.builder(context, _label);
}

/// Shows the received quality of [identity]'s [source], live while the menu is open.
class StreamQualityRow extends StatelessWidget {
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
  Widget build(BuildContext context) => StreamQualityBuilder(
    sampler: sampler,
    identity: identity,
    source: source,
    builder: (context, label) => _row(context, label ?? 'Measuring'),
  );

  Widget _row(BuildContext context, String value) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final touch = AppTouchTargets.of(context);
    final style = (touch ? AppText.body : AppText.ui).copyWith(
      color: tokens.textSecondary,
    );
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
