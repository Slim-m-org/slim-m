// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'client.dart';
import 'client_transport.dart';
import 'models.dart';

/// The Space theme store (decision 0106). Any member publishes; the author or
/// MANAGE_SERVER removes; MANAGE_SERVER sets the default.
extension SlimmApiSpaceThemes on SlimmApi {
  Future<SpaceThemeList> listSpaceThemes() async {
    final json = await send('GET', '/space/themes');
    return SpaceThemeList.fromJson(json as Map<String, dynamic>);
  }

  /// Publishes a theme file; a 400 names every problem the server found.
  Future<SpaceTheme> publishSpaceTheme(Map<String, dynamic> file) async {
    final json = await send('POST', '/space/themes', body: file);
    return SpaceTheme.fromJson(json as Map<String, dynamic>);
  }

  Future<void> deleteSpaceTheme(String themeId) =>
      send('DELETE', '/space/themes/$themeId', expectNoContent: true);

  Future<FetchedBytes> fetchSpaceThemePicture(String themeId) =>
      fetchBytes('/space/themes/$themeId/picture');

  /// Sets the Space default, or clears it with a null [themeId].
  Future<void> setSpaceDefaultTheme(String? themeId) => send(
        'PUT',
        '/space/default-theme',
        body: {'theme_id': themeId},
        expectNoContent: true,
      );
}
