import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/models/stream_source.dart';
import 'package:onfeed/src/services/torrent_source_preparer.dart';

void main() {
  const hash = '98cbfaa598beffe5c00ed6d56655c6b2f608b92e';

  test('reads the info hash from a magnet link', () {
    const source = StreamSource(
      name: 'Film',
      url: 'magnet:?xt=urn:btih:$hash&tr=udp%3A%2F%2Ftracker.example%3A1337',
    );
    expect(TorrentSourcePreparer.topicOf(source), 'urn:btih:$hash');
  });

  test('falls back to the provider-supplied info hash', () {
    const source = StreamSource(name: 'Film', url: '', infoHash: hash);
    expect(TorrentSourcePreparer.topicOf(source), 'urn:btih:$hash');
  });

  test('rejects malformed hashes', () {
    const magnet = StreamSource(
      name: 'Film',
      url: 'magnet:?xt=urn:btih:not-a-hash',
    );
    const field = StreamSource(name: 'Film', url: '', infoHash: 'abc');
    expect(TorrentSourcePreparer.topicOf(magnet), isNull);
    expect(TorrentSourcePreparer.topicOf(field), isNull);
  });
}
