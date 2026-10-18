import 'package:flutter/widgets.dart';
import 'package:material_symbols_icons/symbols.dart';

/// The places in the app's navigation: the TV rail and the Windows sidebar.
enum TvDestination {
  home('Home', Symbols.home_rounded),
  movies('Movies', Symbols.movie_rounded),
  series('Series', Symbols.live_tv_rounded),
  search('Search', Symbols.search_rounded),
  library('My library', Symbols.bookmark_rounded),
  plugins('Plugins', Symbols.extension_rounded),
  settings('Settings', Symbols.settings_rounded);

  const TvDestination(this.label, this.icon);

  final String label;
  final IconData icon;
}
