import 'dart:convert';

import 'package:flutter_js/flutter_js.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/services/provider_fetch_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    final bridge = ProviderFetchBridge(runtime, client);

    try {
      final result = runtime.evaluateAsync('''
        (async function() {
          const url = new URL('/test?old=1', 'https://example.test/base');
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
          const response = await fetch('https://example.test/test', {
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
          xhr.open('GET', 'https://example.test/test');
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
}
