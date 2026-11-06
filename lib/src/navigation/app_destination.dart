import 'package:flutter/widgets.dart';
import '../theme/reelish_icons.dart';

/// The places in the app's navigation: the TV rail and the Windows sidebar.
enum TvDestination {
  home('Home', ReelishIcons.home),
  movies('Movies', ReelishIcons.movie),
  series('Series', ReelishIcons.tv),
  search('Search', ReelishIcons.search),
  library('My library', ReelishIcons.bookmark),
  plugins('Plugins', ReelishIcons.plugin),
  settings('Settings', ReelishIcons.settings),

  /// The signed-in person's page. Drawn with their avatar rather than the
  /// icon: at the foot of the Windows sidebar, at the top of the TV rail.
  profile('Profile', ReelishIcons.account);

  const TvDestination(this.label, this.icon);

  final String label;
  final IconData icon;
}
