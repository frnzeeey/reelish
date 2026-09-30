import 'dart:convert';
import 'dart:io';

import 'package:flutter_js/flutter_js.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/services/provider_fetch_bridge.dart';
import 'package:onfeed/src/services/network_target_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('plugin runtime exposes no native or secret-bearing APIs', () async {
    final runtime = QuickJsRuntime2()..enableHandlePromises();
    final mock = MockClient((request) async {
      fail('private network request reached the HTTP client: ${request.url}');
    });
    final validator = NetworkDestinationValidator(
      lookup: (_) async => [InternetAddress('93.184.216.34')],
    );
    final bridge = ProviderFetchBridge(runtime, mock, validator);

    try {
      final globals = runtime.evaluate('''
        JSON.stringify({
          process: typeof process,
          require: typeof require,
          localStorage: typeof localStorage,
          document: typeof document,
          dart: typeof Dart,
          fetch: typeof fetch,
          cookies: typeof document === 'undefined'
        })
      ''');
      expect(globals.isError, isFalse);
      expect(globals.stringResult, contains('"process":"undefined"'));
      expect(globals.stringResult, contains('"require":"undefined"'));
      expect(globals.stringResult, contains('"localStorage":"undefined"'));
      expect(globals.stringResult, contains('"dart":"undefined"'));
      expect(globals.stringResult, contains('"fetch":"function"'));

      final privateFetch = await runtime.evaluateAsync('''
        fetch('http://127.0.0.1/private')
          .then(() => 'unexpected success')
          .catch(error => 'blocked')
      ''');
      final result = await runtime
          .handlePromise(privateFetch)
          .timeout(const Duration(seconds: 5));
      expect(result.stringResult, 'blocked');
    } finally {
      bridge.dispose();
      mock.close();
      final runtimeId = runtime.getEngineInstanceId();
      runtime.dispose();
      JavascriptRuntime.channelFunctionsRegistered.remove(runtimeId);
    }
  });

  test('fetch bridge rejects a public-to-private redirect', () async {
    var requestCount = 0;
    final runtime = QuickJsRuntime2()..enableHandlePromises();
    final client = MockClient((request) async {
      requestCount++;
      return http.Response(
        '',
        302,
        headers: {'location': 'http://127.0.0.1/private'},
      );
    });
    final validator = NetworkDestinationValidator(
      lookup: (_) async => [InternetAddress('93.184.216.34')],
    );
    final bridge = ProviderFetchBridge(runtime, client, validator);

    try {
      final call = await runtime.evaluateAsync('''
        fetch('https://provider.example.org/start')
          .then(() => 'unexpected success')
          .catch(() => 'blocked')
      ''');
      final result = await runtime
          .handlePromise(call)
          .timeout(const Duration(seconds: 5));
      expect(result.stringResult, 'blocked');
      expect(requestCount, 1);
    } finally {
      bridge.dispose();
      client.close();
      final runtimeId = runtime.getEngineInstanceId();
      runtime.dispose();
      JavascriptRuntime.channelFunctionsRegistered.remove(runtimeId);
    }
  });

  test('fetch returns actual status, response body, and headers', () async {
    final runtime = QuickJsRuntime2()..enableHandlePromises();
    final client = MockClient((request) async {
      expect(request.url.path, '/test');
      if (request.url.queryParameters.containsKey('q')) {
        expect(request.url.queryParameters['q'], 'hello world');
        expect(request.headers['x-test'], 'sent');
      }
      if (request.method == 'POST') {
        expect(request.body, 'token=abc123&name=Reelish+App');
      }
      return http.Response(
        'sample provider response',
        418,
        headers: {'x-provider-check': 'present'},
        request: request,
      );
    });
    final validator = NetworkDestinationValidator(
      lookup: (_) async => [InternetAddress('93.184.216.34')],
    );
    final bridge = ProviderFetchBridge(runtime, client, validator);

    try {
      final result = runtime.evaluateAsync('''
        (async function() {
          const url = new URL('/test?old=1', 'https://provider.example.org/base');
          url.searchParams.set('q', 'hello world');
          const response = await fetch(url, {
            headers: new Headers({ 'X-Test': 'sent' })
          });
          return JSON.stringify({
            status: response.status,
            ok: response.ok,
            header: response.headers.get('x-provider-check'),
            body: await response.text()
          });
        })()
      ''');
      final value = await runtime
          .handlePromise(await result)
          .timeout(const Duration(seconds: 5));
      final decoded = jsonDecode(value.stringResult) as Map<String, dynamic>;

      expect(decoded['status'], 418);
      expect(decoded['ok'], isFalse);
      expect(decoded['header'], 'present');
      expect(decoded['body'], 'sample provider response');

      final formCall = await runtime.evaluateAsync('''
        (async function() {
          const body = new URLSearchParams({
            token: 'abc123',
            name: 'Reelish App'
          }).toString();
          const response = await fetch('https://provider.example.org/test', {
            method: 'POST', body
          });
          return response.status;
        })()
      ''');
      final formValue = await runtime
          .handlePromise(formCall)
          .timeout(const Duration(seconds: 5));
      expect(formValue.stringResult, '418');

      final xhrCall = await runtime.evaluateAsync('''
        new Promise(resolve => {
          const xhr = new XMLHttpRequest();
          xhr.open('GET', 'https://provider.example.org/test');
          xhr.onload = () => resolve(JSON.stringify({
            status: xhr.status,
            header: xhr.getResponseHeader('x-provider-check'),
            body: xhr.responseText
          }));
          xhr.onerror = () => resolve('xhr failed');
          xhr.send();
        })
      ''');
      final xhrValue = await runtime
          .handlePromise(xhrCall)
          .timeout(const Duration(seconds: 5));
      final xhrDecoded =
          jsonDecode(xhrValue.stringResult) as Map<String, dynamic>;
      expect(xhrDecoded['status'], 418);
      expect(xhrDecoded['header'], 'present');
      expect(xhrDecoded['body'], 'sample provider response');
    } finally {
      bridge.dispose();
      client.close();
      final runtimeId = runtime.getEngineInstanceId();
      runtime.dispose();
      JavascriptRuntime.channelFunctionsRegistered.remove(runtimeId);
    }
  });

  test('fetch preserves binary bodies and replays provider cookies', () async {
    var count = 0;
    final runtime = QuickJsRuntime2()..enableHandlePromises();
    final client = MockClient((request) async {
      if (request.url.path == '/compressed') {
        return http.Response.bytes(
          gzip.encode(utf8.encode('compressed text')),
          200,
          headers: {
            'content-encoding': 'gzip',
            'content-type': 'text/plain; charset=utf-8',
          },
          request: request,
        );
      }
      count++;
      if (count == 1) {
        return http.Response(
          '',
          307,
          headers: {
            'location': '/continue',
            'set-cookie': 'session=xyz; Path=/; Secure; HttpOnly',
          },
          request: request,
        );
      }
      expect(request.url.path, '/continue');
      expect(request.headers['cookie'], 'session=xyz');
      expect(request.bodyBytes, [0, 255, 17, 128]);
      return http.Response.bytes([0, 255, 17, 128], 200, request: request);
    });
    final validator = NetworkDestinationValidator(
      lookup: (_) async => [InternetAddress('93.184.216.34')],
    );
    final bridge = ProviderFetchBridge(runtime, client, validator);

    try {
      final call = await runtime.evaluateAsync('''
        (async function() {
          const body = new Uint8Array([0, 255, 17, 128]);
          const response = await fetch('https://provider.example.org/start', {
            method: 'POST', body
          });
          const buffer = await response.arrayBuffer();
          const result = new Uint8Array(buffer);
          let values = '';
          for (let index = 0; index < result.length; index++) {
            values += (index ? ',' : '') + String(result[index]);
          }
          return JSON.stringify({length: buffer.byteLength, values});
        })()
      ''');
      final value = await runtime
          .handlePromise(call)
          .timeout(const Duration(seconds: 5));
      expect(value.stringResult, '{"length":4,"values":"0,255,17,128"}');
      expect(count, 2);

      final compressedCall = await runtime.evaluateAsync('''
        fetch('https://provider.example.org/compressed')
          .then(response => response.text())
      ''');
      final compressedValue = await runtime
          .handlePromise(compressedCall)
          .timeout(const Duration(seconds: 5));
      expect(compressedValue.stringResult, 'compressed text');
    } finally {
      bridge.dispose();
      client.close();
      final runtimeId = runtime.getEngineInstanceId();
      runtime.dispose();
      JavascriptRuntime.channelFunctionsRegistered.remove(runtimeId);
    }
  });

  test(
    'fetch retries malformed compressed GET responses with identity',
    () async {
      var requestCount = 0;
      final runtime = QuickJsRuntime2()..enableHandlePromises();
      final client = MockClient((request) async {
        requestCount++;
        if (requestCount == 1) {
          return http.Response.bytes(
            [1, 2, 3, 4],
            200,
            headers: {
              'content-encoding': 'gzip',
              'content-type': 'application/json',
            },
            request: request,
          );
        }
        expect(request.headers['accept-encoding'], 'identity');
        return http.Response(
          '{"ok":true}',
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      });
      final validator = NetworkDestinationValidator(
        lookup: (_) async => [InternetAddress('93.184.216.34')],
      );
      final bridge = ProviderFetchBridge(runtime, client, validator);

      try {
        final call = await runtime.evaluateAsync('''
        fetch('https://provider.example.org/data').then(response => response.json())
          .then(value => JSON.stringify(value))
      ''');
        final value = await runtime
            .handlePromise(call)
            .timeout(const Duration(seconds: 5));
        expect(value.stringResult, '{"ok":true}');
        expect(requestCount, 2);
      } finally {
        bridge.dispose();
        client.close();
        final runtimeId = runtime.getEngineInstanceId();
        runtime.dispose();
        JavascriptRuntime.channelFunctionsRegistered.remove(runtimeId);
      }
    },
  );
}
