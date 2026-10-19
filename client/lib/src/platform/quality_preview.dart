import 'dart:io';

/// Upstream components used by the community quality preview. These are
/// external GPL-3.0 programs; they are not linked into the YuanLian client and
/// they do not participate in YuanLian accounts, tickets or Host approval.
const String moonlightPreviewVersion = '6.2.0';
const String sunshinePreviewVersion = '2026.914.233613';
const String moonlightUpstreamUrl =
    'https://github.com/moonlight-stream/moonlight-qt';
const String sunshineUpstreamUrl = 'https://github.com/LizardByte/Sunshine';

/// Parameters for the official Moonlight CLI. Kept pure so the argument order
/// and validation can be unit tested without starting a process.
class QualityPreviewConfig {
  const QualityPreviewConfig({
    required this.host,
    required this.app,
    required this.resolution,
    required this.fps,
    required this.bitrateKbps,
    this.videoCodec = 'auto',
    this.videoDecoder = 'auto',
    this.displayMode = 'windowed',
    this.performanceOverlay = true,
  });

  final String host;
  final String app;
  final String resolution;
  final int fps;
  final int bitrateKbps;
  final String videoCodec;
  final String videoDecoder;
  final String displayMode;
  final bool performanceOverlay;

  static const videoCodecs = ['auto', 'H.264', 'HEVC', 'AV1'];
  static const videoDecoders = ['auto', 'hardware', 'software'];
  static const displayModes = ['windowed', 'fullscreen', 'borderless'];

  static const List<String> resolutions = [
    '1280x720',
    '1920x1080',
    '2560x1440',
    '3840x2160',
  ];
  static const List<int> frameRates = [30, 60, 90, 120];

  /// Returns a user-facing reason, or null when the values are acceptable.
  /// The host and app are passed as separate argv entries, never through a
  /// shell, but leading dashes are still rejected so Moonlight cannot parse a
  /// value as another option.
  String? validate() {
    final trimmedHost = host.trim();
    if (trimmedHost.isEmpty) {
      return '请填写 Sunshine Host 地址。';
    }
    if (trimmedHost.length > 253 || trimmedHost.startsWith('-')) {
      return 'Host 地址格式无效。';
    }
    if (!RegExp(r'^[A-Za-z0-9.:\[\]-]+$').hasMatch(trimmedHost)) {
      return 'Host 地址只能包含字母、数字、点、冒号、方括号和连字符。';
    }
    if (!_validEndpoint(trimmedHost)) {
      return 'Host 地址无效，请填写有效 IP 或主机名；自定义端口范围为 1–65535。';
    }
    final trimmedApp = app.trim();
    if (trimmedApp.isEmpty || trimmedApp.length > 128) {
      return '应用名称长度必须为 1–128 个字符。';
    }
    if (trimmedApp.startsWith('-') ||
        trimmedApp.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      return '应用名称不能以连字符开头或包含控制字符。';
    }
    if (!resolutions.contains(resolution)) {
      return '请选择列表中的分辨率。';
    }
    if (!frameRates.contains(fps)) {
      return '帧率必须是 30、60、90 或 120。';
    }
    if (bitrateKbps < 1000 || bitrateKbps > 100000) {
      return '码率必须在 1000–100000 Kbps 之间。';
    }
    if (!videoCodecs.contains(videoCodec) ||
        !videoDecoders.contains(videoDecoder) ||
        !displayModes.contains(displayMode)) {
      return '请选择支持的编码、解码和窗口模式。';
    }
    return null;
  }

  List<String> toArguments() {
    return [
      '--resolution',
      resolution,
      '--fps',
      '$fps',
      '--bitrate',
      '$bitrateKbps',
      '--display-mode',
      displayMode,
      '--video-codec',
      videoCodec,
      '--video-decoder',
      videoDecoder,
      performanceOverlay ? '--performance-overlay' : '--no-performance-overlay',
      'stream',
      host.trim(),
      app.trim(),
    ];
  }

  static bool _validEndpoint(String value) {
    bool validPort(String? port) {
      if (port == null) return true;
      final number = int.tryParse(port);
      return number != null && number >= 1 && number <= 65535;
    }

    if (value.startsWith('[')) {
      final match = RegExp(r'^\[([^\]]+)\](?::([0-9]+))?$').firstMatch(value);
      return match != null &&
          InternetAddress.tryParse(match.group(1)!)?.type ==
              InternetAddressType.IPv6 &&
          validPort(match.group(2));
    }
    if (InternetAddress.tryParse(value) != null) return true;
    final parts = value.split(':');
    if (parts.length > 2 || (parts.length == 2 && !validPort(parts[1]))) {
      return false;
    }
    final host = parts.first;
    if (InternetAddress.tryParse(host) != null) return true;
    if (RegExp(r'^[0-9.]+$').hasMatch(host)) return false;
    final normalized = host.endsWith('.')
        ? host.substring(0, host.length - 1)
        : host;
    final label = RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$');
    return normalized.split('.').every(label.hasMatch);
  }
}

/// Locates the separately distributed preview bundle. The bundle is optional,
/// so every lookup can return null and the UI must show the real reason.
abstract final class QualityPreviewLocator {
  static String? findMoonlight({
    String? executablePath,
    String? workingDirectory,
    Map<String, String>? environment,
  }) {
    return _find(
      executableName: 'Moonlight.exe',
      executablePath: executablePath,
      workingDirectory: workingDirectory,
      environment: environment,
      subdirectory: 'moonlight',
    );
  }

  static String? findSunshine({
    String? executablePath,
    String? workingDirectory,
    Map<String, String>? environment,
  }) {
    final override =
        (environment ?? Platform.environment)['YUANLIAN_QUALITY_PREVIEW'];
    final roots = <String>[
      if (override != null && override.trim().isNotEmpty) override.trim(),
      ..._roots(executablePath, workingDirectory),
    ];
    for (final root in roots) {
      for (final relative in const [
        'sunshine/sunshine.exe',
        'sunshine/Sunshine.exe',
        'windows-x64/sunshine/sunshine.exe',
        'quality-preview/windows-x64/sunshine/sunshine.exe',
        'quality-preview/windows-x64/sunshine/Sunshine.exe',
        'quality-preview/sunshine/sunshine.exe',
        'quality-preview/sunshine/Sunshine.exe',
        'third_party/moonlight/sunshine/Sunshine/sunshine.exe',
      ]) {
        final candidate = File(_join(root, relative));
        if (candidate.existsSync()) {
          return candidate.path;
        }
      }
    }
    return null;
  }

  static String? _find({
    required String executableName,
    required String? executablePath,
    required String? workingDirectory,
    required Map<String, String>? environment,
    required String subdirectory,
  }) {
    final env = environment ?? Platform.environment;
    final override = env['YUANLIAN_QUALITY_PREVIEW'];
    if (override != null && override.trim().isNotEmpty) {
      final direct = File(override.trim());
      if (direct.existsSync() &&
          direct.path.toLowerCase().endsWith(executableName.toLowerCase())) {
        return direct.path;
      }
      for (final relative in [
        '$subdirectory/$executableName',
        'windows-x64/$subdirectory/$executableName',
        executableName,
      ]) {
        final candidate = File(_join(override.trim(), relative));
        if (candidate.existsSync()) {
          return candidate.path;
        }
      }
    }
    for (final root in _roots(executablePath, workingDirectory)) {
      for (final relative in [
        'quality-preview/windows-x64/$subdirectory/$executableName',
        'quality-preview/$subdirectory/$executableName',
        '$subdirectory/$executableName',
        'third_party/moonlight/$subdirectory/$executableName',
      ]) {
        final candidate = File(_join(root, relative));
        if (candidate.existsSync()) {
          return candidate.path;
        }
      }
    }
    return null;
  }

  static List<String> _roots(String? executablePath, String? workingDirectory) {
    final roots = <String>[];
    final exe =
        executablePath ??
        (Platform.isWindows ? Platform.resolvedExecutable : null);
    if (exe != null) {
      var directory = File(exe).parent;
      // Installed layout: <install>/client/yuanlian_client.exe and an optional
      // <install>/quality-preview tree. Three levels cover client, bin and
      // developer build outputs.
      for (var depth = 0; depth < 4; depth++) {
        roots.add(directory.path);
        final parent = directory.parent;
        if (parent.path == directory.path) {
          break;
        }
        directory = parent;
      }
    }
    final cwd = workingDirectory ?? Directory.current.path;
    roots.add(cwd);
    return roots.toSet().toList(growable: false);
  }

  static String _join(String root, String relative) {
    return '$root${Platform.pathSeparator}'
        '${relative.replaceAll('/', Platform.pathSeparator)}';
  }
}
