// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The iPhone's own audio route button, the only way to reach AirPods.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_design_system/design_system.dart';

const audioRoutePickerKey = ValueKey('audio-route-picker');

const _viewType = 'top.npcserver.slimm/route_picker';
const _buttonSize = 44.0;

/// Output row whose trailing control is AVRoutePickerView; [picker] stands in for tests.
class AudioRoutePickerRow extends StatelessWidget {
  const AudioRoutePickerRow({super.key, this.picker});

  final Widget? picker;

  @override
  Widget build(BuildContext context) {
    return AppListRow(
      label: 'Audio output',
      subtitle: 'Choose AirPods, the speaker or this phone.',
      trailing: SizedBox(
        key: audioRoutePickerKey,
        width: _buttonSize,
        height: _buttonSize,
        child:
            picker ??
            const UiKitView(
              viewType: _viewType,
              creationParamsCodec: StandardMessageCodec(),
            ),
      ),
    );
  }
}
