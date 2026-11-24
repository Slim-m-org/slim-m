// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where a link really goes, for text that can say anything.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

const int _maxHostChars = 28;

/// [url]'s host, or null when it has none.
String? destinationHostOf(String? url) {
  if (url == null) return null;
  final host = Uri.tryParse(url)?.host;
  return host == null || host.isEmpty ? null : host;
}

/// [host] cut from the front, so the registrable domain at its end is what stays.
///
/// Whole labels go first, but the last two always stay; past [maxChars] even those lose their first characters.
String elideHostAtFront(String host, {int maxChars = _maxHostChars}) {
  if (host.length <= maxChars) return host;
  final labels = host.split('.');
  var kept = labels.removeLast();
  if (labels.isNotEmpty) kept = '${labels.removeLast()}.$kept';
  while (labels.isNotEmpty &&
      kept.length + labels.last.length + 2 <= maxChars) {
    kept = '${labels.removeLast()}.$kept';
  }
  if (kept.length > maxChars - 1) {
    kept = kept.substring(kept.length - (maxChars - 1));
  }
  return '…$kept';
}

/// The host of [url] as a caption, with the whole address in a tooltip and the semantics.
class LinkDestination extends StatelessWidget {
  const LinkDestination({super.key, required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final host = destinationHostOf(url);
    if (host == null) return const SizedBox.shrink();
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Tooltip(
      message: url,
      child: Semantics(
        label: url,
        excludeSemantics: true,
        child: Text(
          elideHostAtFront(host),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.caption.copyWith(color: tokens.textSecondary),
        ),
      ),
    );
  }
}
