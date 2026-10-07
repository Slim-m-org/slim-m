// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The off-state preview for [AnalyticsScreen]: skeleton stat tiles and
/// chart outlines standing in for the real numbers, so turning analytics on
/// is a decision made with a sense of what appears rather than a blind leap.
///
/// Static, not shimmering: nothing here is "loading" in the network sense,
/// so an animated shimmer would falsely promise data is on its way when the
/// feature is simply off. `AttachmentPlaceholder`
/// (`widgets/message_row_parts.dart`) is the nearest existing skeleton shape
/// - a plain `stripe`-filled box - and every block below reuses that fill.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../widgets/settings_section_header.dart';
import 'admin_stat_tile.dart' show adminStatTileWidth;

/// A fixed, deterministic silhouette rather than random heights, so the
/// ghost renders identically on every build - this feeds the ui-snapshot
/// and golden surfaces, which need a stable capture.
const List<double> _ghostBarHeights = [
  0.35,
  0.62,
  0.48,
  0.8,
  0.4,
  0.7,
  0.3,
  0.58,
  0.66,
  0.42,
  0.74,
  0.5,
];

/// Skeleton tiles and chart outlines for every section [AnalyticsScreen]
/// renders once enabled, in the same order, so a reader scrolling the off
/// state previews exactly what turning the toggle on would replace it with.
class AnalyticsGhostPreview extends StatelessWidget {
  const AnalyticsGhostPreview({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Preview of Space analytics once turned on',
    child: const ExcludeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _GhostStatTiles(),
          SizedBox(height: AppSpacing.s16),
          _GhostChartCard(title: 'Messages, last 30 days'),
          SizedBox(height: AppSpacing.s16),
          _GhostChartCard(title: 'Active hours, last 30 days (UTC)'),
          SizedBox(height: AppSpacing.s16),
          _GhostChartCard(title: 'Server memory use'),
          SizedBox(height: AppSpacing.s16),
          _GhostMemberList(),
        ],
      ),
    ),
  );
}

class _GhostStatTiles extends StatelessWidget {
  const _GhostStatTiles();

  @override
  Widget build(BuildContext context) => const Wrap(
    spacing: AppSpacing.s12,
    runSpacing: AppSpacing.s12,
    children: [
      AdminStatTileGhost(),
      AdminStatTileGhost(),
      AdminStatTileGhost(),
      AdminStatTileGhost(),
    ],
  );
}

class AdminStatTileGhost extends StatelessWidget {
  const AdminStatTileGhost({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox(
    width: adminStatTileWidth,
    child: AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _GhostBlock(width: 64, height: 22),
          SizedBox(height: AppSpacing.s8),
          _GhostBlock(width: 92, height: 12),
        ],
      ),
    ),
  );
}

class _GhostChartCard extends StatelessWidget {
  const _GhostChartCard({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => SettingsSectionCard(
    title: title,
    children: const [
      _GhostBars(),
      SizedBox(height: AppSpacing.s8),
      _GhostBlock(width: 150, height: 12),
    ],
  );
}

/// The bar-chart outline: same silhouette shape as [AnalyticsBarChart], with
/// no axis or scale, because there are no real ticks or a real maximum to
/// label yet.
class _GhostBars extends StatelessWidget {
  const _GhostBars();

  static const double _height = 96;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return SizedBox(
      height: _height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final fraction in _ghostBarHeights) ...[
            Expanded(
              child: FractionallySizedBox(
                heightFactor: fraction,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: tokens.stripe,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(AppRadii.control),
                    ),
                  ),
                ),
              ),
            ),
            if (fraction != _ghostBarHeights.last)
              const SizedBox(width: AppSpacing.s4),
          ],
        ],
      ),
    );
  }
}

class _GhostMemberList extends StatelessWidget {
  const _GhostMemberList();

  @override
  Widget build(BuildContext context) => const SettingsSectionCard(
    title: 'Attachment storage by member',
    children: [
      _GhostMemberRow(),
      SizedBox(height: AppSpacing.s8),
      _GhostMemberRow(),
    ],
  );
}

class _GhostMemberRow extends StatelessWidget {
  const _GhostMemberRow();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: AppSpacing.s4),
    child: Row(
      children: [
        Expanded(child: _GhostBlock(width: double.infinity, height: 14)),
        SizedBox(width: AppSpacing.s12),
        _GhostBlock(width: 56, height: 14),
      ],
    ),
  );
}

/// One `stripe`-filled rounded rectangle - the same fill `AttachmentPlaceholder`
/// uses for an attachment still loading, reused here for "no data because
/// the feature is off" rather than "data on its way".
class _GhostBlock extends StatelessWidget {
  const _GhostBlock({required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: tokens.stripe,
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
    );
  }
}
