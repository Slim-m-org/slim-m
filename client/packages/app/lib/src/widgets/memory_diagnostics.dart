// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A live memory readout for the debug screen: the process's resident size and
/// how full Flutter's decoded-image cache is.
///
/// It exists because client memory was, until now, a number nobody in the app
/// could see - the perf baselines track only the server. The resident size is
/// the same figure a task manager shows, so "why is it 400 MB" can be answered
/// from inside the app; the image-cache line is the one pool the Appearance
/// setting caps, shown against that cap so the effect of lowering it is
/// visible.
///
/// Resident size comes from `dart:io`'s [ProcessInfo], which the web has no
/// equivalent for, so that line reads "unavailable on web" there rather than
/// throwing. Nothing here is sampled on a timer; it reads on build and on the
/// refresh button, because a readout that repaints every second is its own
/// small drain on the thing it measures.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'attachment_format.dart';
import 'settings_section_header.dart';

import 'memory_diagnostics_io.dart'
    if (dart.library.js_interop) 'memory_diagnostics_web.dart';

class MemoryDiagnostics extends StatefulWidget {
  const MemoryDiagnostics({super.key});

  @override
  State<MemoryDiagnostics> createState() => _MemoryDiagnosticsState();
}

class _MemoryDiagnosticsState extends State<MemoryDiagnostics> {
  DateTime _updated = DateTime.now();

  String get _updatedLabel {
    String two(int n) => n.toString().padLeft(2, '0');
    return 'Updated ${two(_updated.hour)}:${two(_updated.minute)}:'
        '${two(_updated.second)}.';
  }

  @override
  Widget build(BuildContext context) {
    final cache = PaintingBinding.instance.imageCache;
    final rss = currentResidentBytes();

    return SettingsSectionCard(
      flush: true,
      title: 'Memory',
      description: _updatedLabel,
      trailing: AppIconButton(
        icon: AppIcons.retry,
        semanticLabel: 'Refresh memory readout',
        tooltip: 'Refresh memory readout',
        iconSize: AppSizes.icon16,
        onPressed: () => setState(() => _updated = DateTime.now()),
      ),
      children: [
        if (rss != null)
          _MemoryRow(
            label: 'Resident set (process)',
            value: formatByteSize(rss),
          ),
        _MemoryRow(
          label: 'Image cache',
          value: formatByteSize(cache.currentSizeBytes),
          of: 'of ${formatByteSize(cache.maximumSizeBytes)}',
          fraction: _fraction(cache.currentSizeBytes, cache.maximumSizeBytes),
        ),
        _MemoryRow(
          label: 'Image cache entries',
          value: '${cache.currentSize}',
          of: 'of ${cache.maximumSize}',
          fraction: _fraction(cache.currentSize, cache.maximumSize),
        ),
      ],
    );
  }

  static double _fraction(int used, int max) =>
      max <= 0 ? 0 : (used / max).clamp(0.0, 1.0);
}

/// A label and a mono value, with a thin fill bar under it when the value is a share of a cap.
class _MemoryRow extends StatelessWidget {
  const _MemoryRow({
    required this.label,
    required this.value,
    this.of,
    this.fraction,
  });

  final String label;
  final String value;
  final String? of;
  final double? fraction;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final mono = AppText.caption.copyWith(fontFamily: AppFonts.mono);
    return Container(
      constraints: BoxConstraints(minHeight: fraction == null ? 56 : 0),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s16,
        vertical: 14,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: AppText.ui.copyWith(color: tokens.textPrimary),
                ),
              ),
              Text.rich(
                TextSpan(
                  text: value,
                  style: mono.copyWith(color: tokens.textPrimary),
                  children: [
                    if (of != null)
                      TextSpan(
                        text: ' $of',
                        style: TextStyle(color: tokens.textSecondary),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (fraction != null) ...[
            const SizedBox(height: AppSpacing.s8),
            _FillBar(fraction: fraction!),
          ],
        ],
      ),
    );
  }
}

class _FillBar extends StatelessWidget {
  const _FillBar({required this.fraction});

  final double fraction;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.full),
        child: Container(
          height: 4,
          color: tokens.surfaceSunken,
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: fraction,
            child: ColoredBox(color: tokens.textSecondary),
          ),
        ),
      ),
    );
  }
}
