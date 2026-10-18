import 'dart:convert';

import 'package:http/http.dart' as http;

class ServerException implements Exception {
  ServerException(this.statusCode, this.code, this.message);
  final int statusCode;
  final String code;
  final String message;

  @override
  String toString() => message;
}

class ServerInfo {
  const ServerInfo({
    required this.name,
    required this.version,
    required this.initialized,
    required this.users,
  });
  final String name;
  final String version;
  final bool initialized;
  final int users;
}

class AccountInfo {
  const AccountInfo({
    required this.id,
    required this.username,
    required this.role,
  });
  final int id;
  final String username;
  final String role;
}

class DeviceInfo {
  const DeviceInfo({
    required this.deviceId,
    required this.name,
    required this.owner,
    required this.platform,
    required this.address,
    required this.fingerprint,
    required this.status,
    required this.lastSeen,
    required this.shared,
    required this.permissions,
  });

  final String deviceId;
  final String name;
  final String owner;
  final String platform;
  final String address;
  final String fingerprint;
  final String status;
  final int lastSeen;
  final bool shared;
  final List<String> permissions;

  bool get active => status == 'active';
  bool get online =>
      lastSeen > 0 &&
      DateTime.now().millisecondsSinceEpoch ~/ 1000 - lastSeen < 120;
}

class SessionTicket {
  const SessionTicket({
    required this.ticket,
    required this.sessionId,
    required this.expiresAt,
    required this.permissions,
    required this.deviceId,
    required this.name,
    required this.address,
    required this.fingerprint,
  });

  final String ticket;
  final String sessionId;
  final int expiresAt;
  final int permissions;
  final String deviceId;
  final String name;
  final String address;
  final String fingerprint;
}

class DeviceSession {
  const DeviceSession({
    required this.sessionId,
    required this.userId,
    required this.user,
    required this.permissions,
    required this.startedAt,
    required this.revoked,
  });

  final String sessionId;
  final int userId;
  final String user;
  final int permissions;
  final int startedAt;
  final bool revoked;
}

class RegisterDeviceResult {
  const RegisterDeviceResult({required this.device, required this.deviceToken});
  final DeviceInfo device;
  final String deviceToken;
}

class LoginResult {
  const LoginResult({
    required this.token,
    required this.expiresAt,
    required this.account,
  });
  final String token;
  final int expiresAt;
  final AccountInfo account;
}

/// HTTP client for the YuanLian control plane. It never falls back to any
/// other server: the configured address is authoritative and all failures are
/// reported with their real status/code.
class ServerApi {
  ServerApi({required String baseUrl, http.Client? client})
      : baseUrl = _normalizeBase(baseUrl),
        _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;
  String? token;

  static String _normalizeBase(String value) {
    final text = value.trim();
    final uri = Uri.tryParse(text);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw const FormatException('服务端地址必须是 http:// 或 https:// URL');
    }
    return text.replaceAll(RegExp(r'/+$'), '');
  }

  void dispose() {
    _client.close();
  }

  Future<ServerInfo> info() async {
    final json = await _request('GET', '/api/v1/server/info');
    return ServerInfo(
      name: _string(json['name']),
      version: _string(json['version']),
      initialized: json['initialized'] == true,
      users: _int(json['users']),
    );
  }

  Future<LoginResult> login(String username, String password) async {
    final json = await _request(
      'POST',
      '/api/v1/auth/login',
      body: {'username': username, 'password': password},
    );
    return _loginResult(json);
  }

  Future<LoginResult> registerWithInvite({
    required String inviteCode,
    required String username,
    required String password,
  }) async {
    final json = await _request(
      'POST',
      '/api/v1/auth/register',
      body: {
        'invite_code': inviteCode,
        'username': username,
        'password': password,
      },
    );
    return _loginResult(json);
  }

  Future<void> logout() async {
    await _request('POST', '/api/v1/auth/logout');
    token = null;
  }

  Future<AccountInfo> me() async {
    final json = await _request('GET', '/api/v1/me');
    final user = json['user'] as Map<String, Object?>? ?? json;
    return AccountInfo(
      id: _int(user['id']),
      username: _string(user['username']),
      role: _string(user['role']),
    );
  }

  Future<List<DeviceInfo>> devices() async {
    final json = await _request('GET', '/api/v1/devices');
    final list = json['devices'];
    if (list is! List) {
      return const <DeviceInfo>[];
    }
    return list
        .whereType<Map<String, Object?>>()
        .map(_device)
        .toList(growable: false);
  }

  Future<RegisterDeviceResult> registerDevice({
    required String name,
    required String address,
    required String fingerprint,
    String platform = 'windows',
  }) async {
    final json = await _request(
      'POST',
      '/api/v1/devices',
      body: {
        'name': name,
        'platform': platform,
        'address': address,
        'fingerprint': fingerprint,
      },
    );
    return RegisterDeviceResult(
      device: _device(json['device'] as Map<String, Object?>? ?? const {}),
      deviceToken: _string(json['device_token']),
    );
  }

  Future<SessionTicket> sessionTicket(String deviceId, String nonce) async {
    final json = await _request(
      'POST',
      '/api/v1/devices/$deviceId/session-ticket',
      body: {'nonce': nonce},
    );
    return SessionTicket(
      ticket: _string(json['ticket']),
      sessionId: _string(json['session_id']),
      expiresAt: _int(json['expires_at']),
      permissions: _int(json['permissions']),
      deviceId: _string(json['device_id']),
      name: _string(json['name']),
      address: _string(json['address']),
      fingerprint: _string(json['fingerprint']),
    );
  }

  Future<void> claimPairing(String code) async {
    await _request(
      'POST',
      '/api/v1/pairing/claim',
      body: {'code': code.trim().toUpperCase()},
    );
  }

  Future<List<DeviceSession>> sessions(String deviceId) async {
    final json = await _request('GET', '/api/v1/devices/$deviceId/sessions');
    final list = json['sessions'];
    if (list is! List) {
      return const <DeviceSession>[];
    }
    return list.whereType<Map<String, Object?>>().map((item) {
      return DeviceSession(
        sessionId: _string(item['session_id']),
        userId: _int(item['user_id']),
        user: _string(item['user']),
        permissions: _int(item['permissions']),
        startedAt: _int(item['started_at']),
        revoked: item['revoked'] == true,
      );
    }).toList(growable: false);
  }

  Future<int> revokeSessions(String deviceId, {String? sessionId}) async {
    final body = <String, Object?>{};
    if (sessionId != null) {
      body['session_id'] = sessionId;
    }
    final json = await _request(
      'POST',
      '/api/v1/devices/$deviceId/sessions/revoke',
      body: body,
    );
    return _int(json['revoked']);
  }

  Future<void> revokeDevice(String deviceId) async {
    await _request('POST', '/api/v1/devices/$deviceId/revoke');
  }

  Future<Map<String, Object?>> _request(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    final headers = <String, String>{'accept': 'application/json'};
    if (body != null) {
      headers['content-type'] = 'application/json';
    }
    if (token != null && token!.isNotEmpty) {
      headers['authorization'] = 'Bearer ${token!}';
    }
    late final http.Response response;
    try {
      final request = http.Request(method, uri)
        ..headers.addAll(headers)
        ..body = body == null ? '' : jsonEncode(body);
      final streamed = await _client
          .send(request)
          .timeout(const Duration(seconds: 12));
      response = await http.Response.fromStream(streamed)
          .timeout(const Duration(seconds: 12));
    } on Object catch (error) {
      throw ServerException(0, 'network', '无法连接服务端：$error');
    }
    Map<String, Object?> json;
    try {
      final decoded = response.body.isEmpty
          ? <String, Object?>{}
          : jsonDecode(response.body);
      json = decoded is Map<String, Object?> ? decoded : <String, Object?>{};
    } on Object {
      throw ServerException(
        response.statusCode,
        'bad_response',
        '服务端返回了无法解析的响应（HTTP ${response.statusCode}）',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = json['error'];
      final code = error is Map ? _string(error['code']) : 'http_error';
      final message = error is Map
          ? _string(error['message'])
          : 'HTTP ${response.statusCode}';
      throw ServerException(response.statusCode, code, message);
    }
    return json;
  }

  LoginResult _loginResult(Map<String, Object?> json) {
    final account = json['user'] as Map<String, Object?>? ?? const {};
    final result = LoginResult(
      token: _string(json['token']),
      expiresAt: _int(json['expires_at']),
      account: AccountInfo(
        id: _int(account['id']),
        username: _string(account['username']),
        role: _string(account['role']),
      ),
    );
    token = result.token;
    return result;
  }

  DeviceInfo _device(Map<String, Object?> json) {
    final grant = json['grant'];
    final permissionValue = grant is Map ? grant['permissions'] : null;
    final permissions = <String>[];
    if (permissionValue is List) {
      for (final item in permissionValue) {
        if (item is String) {
          permissions.add(item);
        }
      }
    }
    return DeviceInfo(
      deviceId: _string(json['device_id']),
      name: _string(json['name']),
      owner: _string(json['owner']),
      platform: _string(json['platform']),
      address: _string(json['address']),
      fingerprint: _string(json['fingerprint']),
      status: _string(json['status']),
      lastSeen: _int(json['last_seen']),
      shared: json['shared'] == true,
      permissions: permissions,
    );
  }

  static String _string(Object? value) => value is String ? value : '';

  static int _int(Object? value) => value is num ? value.toInt() : 0;
}
