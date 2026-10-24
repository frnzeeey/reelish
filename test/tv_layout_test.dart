import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/models/media_details.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/screens/tv/tv_browse.dart';
import 'package:onfeed/src/screens/tv/tv_details_screen.dart';
import 'package:onfeed/src/services/tmdb_service.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/widgets/tv/tv_focus.dart';

/// Android TV layout details: backdrops cover their area to the edges,
/// start on a whole device pixel, and action labels use the app's font.

const _movie = MediaItem(
  id: '8',
  type: 'movie',
  name: 'Film',
  year: '2021',
  background: 'https://image.tmdb.org/t/p/w1280/b.jpg',
);

/// Serves one 16:9 PNG for every image request, so backdrops really load:
/// a picture that never loads fills any box and hides the layout.
class _Images extends HttpOverrides {
  _Images(this.png);

  final List<int> png;

  @override
  HttpClient createHttpClient(SecurityContext? context) => _Client(png);
}

class _Client implements HttpClient {
  _Client(this.png);

  final List<int> png;

  @override
  bool autoUncompress = true;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _Request(png);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Request implements HttpClientRequest {
  _Request(this.png);

  final List<int> png;

  @override
  HttpHeaders get headers => _Headers();

  @override
  Future<HttpClientResponse> close() async => _Response(png);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Headers implements HttpHeaders {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.bytes);

  final List<int> bytes;

  @override
  int get statusCode => 200;

  @override
  int get contentLength => bytes.length;

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Future<List<int>> _png16x9() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 160, 90),
    Paint()..color = const Color(0xFF3366AA),
  );
  final image = await recorder.endRecording().toImage(160, 90);
  return (await image.toByteData(
    format: ui.ImageByteFormat.png,
  ))!.buffer.asUint8List();
}

class _Tmdb extends TmdbService {
  @override
  Future<MediaDetails> details(
    MediaItem item, {
    bool forceRefresh = false,
    void Function(MediaDetails)? onRevalidated,
  }) async => const MediaDetails(overview: 'A plot.');
}

/// A 1080p TV: 960 × 540 logical pixels at 2×.
Future<void> _tv(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: GlassTheme.tv, home: child));
  await tester.pump();
}

void main() {
  testWidgets('the browse backdrop covers its whole area', (tester) async {
    final png = (await tester.runAsync(_png16x9))!;
    final previous = HttpOverrides.current;
    HttpOverrides.global = _Images(png);
    addTearDown(() => HttpOverrides.global = previous);
    final featured = TvFeaturedController(_movie);
    addTearDown(featured.dispose);
    await _tv(
      tester,
      Scaffold(
        body: TvBrowseFrame(featured: featured, child: const SizedBox()),
      ),
    );
    // Let the picture download and decode, so it lays out at its own size.
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    final image = tester.getRect(find.byType(Image));
    // Full height of its box (78 % of the screen) from the top edge, not a
    // 16:9 picture centred in it with bands above and below.
    expect(image.top, 0);
    expect(image.height, closeTo(540 * .78, .01));
    expect(image.right, 960);
  });

  testWidgets('backdrops start on a whole device pixel', (tester) async {
    for (final (size, ratio) in const [
      (Size(1920, 1080), 2.0),
      (Size(1280, 720), 4 / 3),
      (Size(3840, 2160), 4.0),
    ]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = ratio;
      late BuildContext context;
      await tester.pumpWidget(
        Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      );
      for (final fraction in const [.74, .78]) {
        final left = (size.width / ratio - tvBackdropWidth(context, fraction));
        final physical = left * ratio;
        expect(
          physical,
          closeTo(physical.roundToDouble(), 1e-6),
          reason: '$size at ${ratio}x, $fraction',
        );
      }
    }
    tester.view.reset();
  });

  testWidgets('the details actions use the app font', (tester) async {
    await _tv(
      tester,
      TvMediaDetailsScreen(
        item: _movie,
        tmdb: _Tmdb(),
        onPlay: (_) {},
        onPlayEpisode: (_, _, _) {},
        onToggleFavorite: () async => true,
      ),
    );
    for (final label in ['Play movie', 'My list']) {
      final paragraph = tester.renderObject<RenderParagraph>(find.text(label));
      expect(
        paragraph.text.style?.fontFamily,
        GlassTheme.fontFamily,
        reason: label,
      );
    }
  });
}
