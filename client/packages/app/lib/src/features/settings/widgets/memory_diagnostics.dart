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

import '../../../widgets/attachment_format.dart';
import 'settings_meter_row.dart';
import 'settings_refresh_button.dart';
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
      title: 'Memory',
      description: _updatedLabel,
      trailing: SettingsRefreshButton(
        label: 'Refresh memory readout',
        onPressed: () => setState(() => _updated = DateTime.now()),
      ),
      children: [
        if (rss != null)
          SettingsMeterRow(
            label: 'Resident set (process)',
            value: formatByteSize(rss),
          ),
        SettingsMeterRow(
          label: 'Image cache',
          value: formatByteSize(cache.currentSizeBytes),
          of: 'of ${formatByteSize(cache.maximumSizeBytes)}',
          fraction: meterFraction(
            cache.currentSizeBytes,
            cache.maximumSizeBytes,
          ),
        ),
        SettingsMeterRow(
          label: 'Image cache entries',
          value: '${cache.currentSize}',
          of: 'of ${cache.maximumSize}',
          fraction: meterFraction(cache.currentSize, cache.maximumSize),
        ),
      ],
    );
  }
}
