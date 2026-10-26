# Windows: an FFI plugin. The Go engine is prebuilt (go/build_windows.ps1)
# into shared/torrent_streamer.dll; Flutter copies it next to Reelish.exe,
# where lib/flutter_go_torrent_streamer.dart loads it by full path.
cmake_minimum_required(VERSION 3.14)
project(flutter_go_torrent_streamer LANGUAGES CXX)

set(TORRENT_STREAMER_DLL "${CMAKE_CURRENT_SOURCE_DIR}/shared/torrent_streamer.dll")
# Without the DLL the app still builds; torrent playback then stays off
# (TorrentSupport.available is false).
if(EXISTS "${TORRENT_STREAMER_DLL}")
  set(flutter_go_torrent_streamer_bundled_libraries
    "${TORRENT_STREAMER_DLL}"
    PARENT_SCOPE
  )
else()
  message(WARNING "torrent_streamer.dll not found; torrent playback is off.")
  set(flutter_go_torrent_streamer_bundled_libraries "" PARENT_SCOPE)
endif()
