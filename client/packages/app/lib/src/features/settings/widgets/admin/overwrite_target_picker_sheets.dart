// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [ChannelPickerSheet] for `channel_permissions_screen.dart`'s channel choice.
///
/// It takes an already-resolved list: its caller awaits a one-shot
/// `store.watchChannels().first` rather than a live provider.
library;

import 'package:flutter/material.dart';
import 'package:slimm_data/data.dart' show Channel;
import 'package:slimm_design_system/design_system.dart';

import '../../../channels/providers/dms.dart' show dmChannelKind;

/// The ceiling a resolved list may grow to before it scrolls internally
/// rather than pushing the sheet past the window - never a size the sheet
/// is forced to regardless of how few rows there are; see
/// [_PickerList]'s own doc.
const _pickerListMaxHeightFraction = 0.6;

const _headingPadding = EdgeInsets.fromLTRB(
  AppSpacing.s16,
  0,
  AppSpacing.s16,
  AppSpacing.s12,
);

class ChannelPickerSheet extends StatelessWidget {
  const ChannelPickerSheet({super.key, required this.channels});

  final List<Channel> channels;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: _headingPadding,
            child: Text('Choose a channel', style: AppText.heading),
          ),
          _PickerList(
            children: [
              // A DM carries no overwrites or webhooks; it is a person, not a channel.
              for (final c in channels.where((c) => c.kind != dmChannelKind))
                AppListRow(
                  leading: Icon(
                    c.kind == 'voice' ? AppIcons.voice : AppIcons.hash,
                  ),
                  label: c.name,
                  onTap: () => Navigator.of(context).pop(c),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A resolved list of rows: sized to its content, up to
/// [_pickerListMaxHeightFraction] of the window, past which it scrolls
/// internally rather than growing further. `shrinkWrap: true` is what makes
/// two or three rows read as two or three rows rather than a card with most
/// of it empty - the previous fixed-fraction `SizedBox` forced this height
/// regardless of row count, the inverse of `avatar-crop-sheet`'s own
/// previously-shipped "too tall for the window" bug: this one was "too tall
/// for too little content."
class _PickerList extends StatelessWidget {
  const _PickerList({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(
      maxHeight:
          MediaQuery.sizeOf(context).height * _pickerListMaxHeightFraction,
    ),
    child: ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.only(bottom: AppSpacing.s8),
      children: children,
    ),
  );
}
