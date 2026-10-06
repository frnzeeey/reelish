// Streams a public-domain torrent through the vendored torrent library on a
// device or emulator, so a rebuilt libtorrent_streamer.so is checked end to
// end: it loads (including on 16 KB page devices), finds peers, reads the
// metadata and serves bytes on its loopback URL.
//
//   flutter test integration_test/torrent_streamer_test.dart -d <device>
//
// Needs internet and BitTorrent peers for Big Buck Bunny (Blender, CC BY).
import 'dart:io';

import 'package:flutter_go_torrent_streamer/flutter_go_torrent_streamer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _bigBuckBunny =
    'magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c'
    '&dn=Big+Buck+Bunny'
    '&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce'
    '&tr=udp%3A%2F%2Fexplodie.org%3A6969'
    '&tr=udp%3A%2F%2Ftracker.torrent.eu.org%3A451%2Fannounce'
    '&tr=udp%3A%2F%2Fopen.stealth.si%3A80%2Fannounce'
    '&ws=https%3A%2F%2Fwebtorrent.io%2Ftorrents%2F';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('streams the first bytes of a torrent', () async {
    final directory = await Directory.systemTemp.createTemp('torrent-test-');
    final session = await FlutterTorrentStreamer().startStream(
      _bigBuckBunny,
      directory.path,
    );
    try {
      var files = <TorrentFile>[];
      final deadline = DateTime.now().add(const Duration(minutes: 2));
      while (files.isEmpty && DateTime.now().isBefore(deadline)) {
        files = await session.getFiles();
        if (files.isEmpty) {
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }
      expect(files, isNotEmpty, reason: 'torrent metadata did not arrive');
      final video = files.firstWhere((file) => file.name.endsWith('.mp4'));
      await session.selectFile(video.index);

      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(session.streamUrl));
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-65535');
        final response = await request.close().timeout(
          const Duration(minutes: 2),
        );
        final bytes = await response
            .fold<List<int>>([], (all, chunk) => all..addAll(chunk))
            .timeout(const Duration(minutes: 2));
        // ignore: avoid_print
        print(
          'TORRENT ${video.name} ${video.size} bytes; '
          'HTTP ${response.statusCode}, read ${bytes.length} bytes',
        );
        expect(response.statusCode, anyOf(200, 206));
        // An MP4 starts with an `ftyp` box.
        expect(String.fromCharCodes(bytes.sublist(4, 8)), 'ftyp');
      } finally {
        client.close(force: true);
      }
    } finally {
      await session.stop();
      await directory.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 6)));
}
