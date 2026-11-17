// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The channel a web page load opened on, until the app first shows anything
/// else. A reload onto a voice channel shows it without joining the call.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'routes.dart';

class LaunchRoute {
  LaunchRoute(String location) : _channelId = _channelOf(location);

  String? _channelId;

  /// Whether this arrival is the page load itself; true at most once, and
  /// any arrival uses it up.
  bool takeArrival(String channelId) {
    final hit = _channelId == channelId;
    _channelId = null;
    return hit;
  }

  /// The app showed [path] first, so no later arrival is the page load.
  void showed(String path) {
    final id = _channelId;
    if (id != null && path != Routes.channel(id)) _channelId = null;
  }

  static String? _channelOf(String location) {
    final segments = Uri.parse(location).pathSegments;
    return segments.length == 2 && '/${segments.first}' == Routes.channels
        ? segments.last
        : null;
  }
}

/// On a native host the launch location is `/`, so nothing ever matches.
final launchRouteProvider = Provider<LaunchRoute>(
  (ref) =>
      LaunchRoute(WidgetsBinding.instance.platformDispatcher.defaultRouteName),
);
