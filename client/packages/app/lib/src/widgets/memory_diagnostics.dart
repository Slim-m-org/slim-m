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
  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final cache = PaintingBinding.instance.imageCache;
    final rss = currentResidentBytes();

    return SettingsSectionCard(
      children: [
        Padding(
          padding: const EdgeInsets.all(AppSpacing.s12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Memory',
                      style: AppText.ui.copyWith(
                        color: tokens.textPrimary,
                        fontWeight: AppWeights.semi,
                      ),
                    ),
                  ),
                  AppIconButton(
                    icon: AppIcons.retry,
                    semanticLabel: 'Refresh memory readout',
                    size: AppIconButtonSize.sm,
                    onPressed: () => setState(() {}),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.s8),
              _Line(
                label: 'Resident set (process)',
                value: rss == null ? 'unavailable on web' : formatByteSize(rss),
                tokens: tokens,
              ),
              _Line(
                label: 'Image cache',
                value:
                    '${formatByteSize(cache.currentSizeBytes)} of '
                    '${formatByteSize(cache.maximumSizeBytes)}',
                tokens: tokens,
              ),
              _Line(
                label: 'Image cache entries',
                value: '${cache.currentSize} of ${cache.maximumSize}',
                tokens: tokens,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.label, required this.value, required this.tokens});

  final String label;
  final String value;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.s4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            label,
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
        ),
        Text(
          value,
          style: AppText.caption.copyWith(
            color: tokens.textPrimary,
            fontFamily: AppFonts.mono,
          ),
        ),
      ],
    ),
  );
}
