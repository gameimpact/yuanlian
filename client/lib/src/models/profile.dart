import 'dart:convert';
import 'dart:io';

class ConnectionProfile {
  const ConnectionProfile({
    required this.name,
    required this.address,
    required this.fingerprint,
    this.lastConnected,
  });

  final String name;
  final String address;
  final String fingerprint;
  final DateTime? lastConnected;

  ConnectionProfile copyWith({
    String? name,
    String? address,
    String? fingerprint,
    DateTime? lastConnected,
  }) {
    return ConnectionProfile(
      name: name ?? this.name,
      address: address ?? this.address,
      fingerprint: fingerprint ?? this.fingerprint,
      lastConnected: lastConnected ?? this.lastConnected,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'address': address,
    'fingerprint': fingerprint,
    'lastConnected': lastConnected?.toIso8601String(),
  };

  factory ConnectionProfile.fromJson(Map<String, Object?> json) {
    final last = json['lastConnected'] as String?;
    return ConnectionProfile(
      name: (json['name'] as String?)?.trim().isNotEmpty == true
          ? json['name'] as String
          : '未命名设备',
      address: json['address'] as String? ?? '',
      fingerprint: json['fingerprint'] as String? ?? '',
      lastConnected: last == null ? null : DateTime.tryParse(last),
    );
  }

  static String? validateAddress(String value) {
    final text = value.trim();
    if (text.isEmpty) {
      return '请输入 Host 地址';
    }
    try {
      final host = text.startsWith('[')
          ? text.substring(1, text.indexOf(']'))
          : text.split(':').first;
      if (host.trim().isEmpty) {
        return '地址格式无效';
      }
      if (!text.startsWith('[') && ':'.allMatches(text).length > 1) {
        return 'IPv6 地址请使用 [地址]:端口';
      }
      if (text.contains(':')) {
        final portText = text.startsWith('[')
            ? text.substring(text.indexOf(']') + 1).replaceFirst(':', '')
            : text.substring(text.lastIndexOf(':') + 1);
        if (portText.isNotEmpty) {
          final port = int.tryParse(portText);
          if (port == null || port < 1 || port > 65535) {
            return '端口必须在 1-65535 之间';
          }
        }
      }
    } on Object {
      return '地址格式无效';
    }
    return null;
  }

  static String? validateFingerprint(String value) {
    final clean = value.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    if (clean.length != 64) {
      return '指纹需要 64 个十六进制字符';
    }
    return null;
  }
}

/// Profiles and UI preferences are plain local JSON; no credentials or device
/// private keys are stored here.
class LocalStore {
  static Future<Directory> _directory() async {
    final base = Platform.environment['APPDATA'] ??
        Platform.environment['XDG_CONFIG_HOME'] ??
        Directory.systemTemp.path;
    final directory = Directory('$base${Platform.pathSeparator}YuanLian');
    await directory.create(recursive: true);
    return directory;
  }

  static Future<File> _profilesFile() async {
    final directory = await _directory();
    return File('${directory.path}${Platform.pathSeparator}profiles.json');
  }

  static Future<File> _settingsFile() async {
    final directory = await _directory();
    return File('${directory.path}${Platform.pathSeparator}settings.json');
  }

  static Future<List<ConnectionProfile>> loadProfiles() async {
    try {
      final file = await _profilesFile();
      if (!await file.exists()) {
        return <ConnectionProfile>[];
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) {
        return <ConnectionProfile>[];
      }
      return decoded
          .whereType<Map<String, Object?>>()
          .map(ConnectionProfile.fromJson)
          .where((profile) => profile.address.isNotEmpty)
          .toList();
    } on Object {
      return <ConnectionProfile>[];
    }
  }

  static Future<void> saveProfiles(List<ConnectionProfile> profiles) async {
    final file = await _profilesFile();
    final payload = const JsonEncoder.withIndent('  ').convert(
      profiles.map((profile) => profile.toJson()).toList(),
    );
    await file.writeAsString(payload, flush: true);
  }

  static Future<Map<String, Object?>> loadSettings() async {
    try {
      final file = await _settingsFile();
      if (!await file.exists()) {
        return <String, Object?>{};
      }
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, Object?> ? decoded : <String, Object?>{};
    } on Object {
      return <String, Object?>{};
    }
  }

  static Future<void> saveSettings(Map<String, Object?> values) async {
    final file = await _settingsFile();
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(values),
      flush: true,
    );
  }
}
