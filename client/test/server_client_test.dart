import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yuanlian_client/src/net/server_client.dart';

void main() {
  test('rejects non-http server addresses', () {
    expect(
      () => ServerApi(baseUrl: 'ftp://example.com'),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => ServerApi(baseUrl: 'example.com:18080'),
      throwsA(isA<FormatException>()),
    );
  });

  test('logs in, sends the bearer token and parses devices and tickets',
      () async {
    final seen = <String>[];
    final client = MockClient((request) async {
      seen.add('${request.method} ${request.url.path}');
      if (request.url.path == '/api/v1/auth/login') {
        return http.Response(
          jsonEncode({
            'token': 'token-1',
            'expires_at': 2000,
            'user': {'id': 1, 'username': 'alice', 'role': 'admin'},
          }),
          200,
        );
      }
      if (request.url.path == '/api/v1/devices') {
        expect(request.headers['authorization'], 'Bearer token-1');
        return http.Response(
          jsonEncode({
            'devices': [
              {
                'device_id': 'yl-1',
                'name': 'Desk',
                'owner': 'alice',
                'platform': 'windows',
                'address': '10.0.0.2:24800',
                'fingerprint': 'aa' * 32,
                'status': 'active',
                'last_seen': 1000,
                'shared': false,
                'grant': null,
              },
            ],
          }),
          200,
        );
      }
      if (request.url.path == '/api/v1/devices/yl-1/session-ticket') {
        final body = jsonDecode(request.body) as Map<String, Object?>;
        expect(body['nonce'], 'ab' * 32);
        return http.Response(
          jsonEncode({
            'ticket': 'yl1.payload.signature',
            'session_id': 'session-1',
            'expires_at': 3000,
            'permissions': 3,
            'device_id': 'yl-1',
            'name': 'Desk',
            'address': '10.0.0.2:24800',
            'fingerprint': 'aa' * 32,
          }),
          200,
        );
      }
      return http.Response('{}', 404);
    });
    final api = ServerApi(baseUrl: 'http://127.0.0.1:18080', client: client);
    addTearDown(api.dispose);
    final login = await api.login('alice', 'password-123');
    expect(login.account.username, 'alice');
    expect(api.token, 'token-1');
    final devices = await api.devices();
    expect(devices.single.deviceId, 'yl-1');
    expect(devices.single.active, true);
    final ticket = await api.sessionTicket('yl-1', 'ab' * 32);
    expect(ticket.sessionId, 'session-1');
    expect(ticket.permissions, 3);
    expect(seen, [
      'POST /api/v1/auth/login',
      'GET /api/v1/devices',
      'POST /api/v1/devices/yl-1/session-ticket',
    ]);
  });

  test('surfaces the server error code and message', () async {
    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'error': {'code': 'forbidden', 'message': 'grant does not include view'},
        }),
        403,
      );
    });
    final api = ServerApi(baseUrl: 'https://control.example.com', client: client);
    addTearDown(api.dispose);
    await expectLater(
      api.devices(),
      throwsA(
        isA<ServerException>()
            .having((error) => error.statusCode, 'status', 403)
            .having((error) => error.code, 'code', 'forbidden')
            .having((error) => error.message, 'message', contains('view')),
      ),
    );
  });
}
