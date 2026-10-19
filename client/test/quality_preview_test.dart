import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yuanlian_client/src/platform/quality_preview.dart';

void main() {
  group('QualityPreviewConfig', () {
    const valid = QualityPreviewConfig(
      host: '192.168.1.10',
      app: 'Desktop',
      resolution: '1920x1080',
      fps: 60,
      bitrateKbps: 20000,
    );

    test('builds Moonlight CLI arguments in stream order', () {
      expect(valid.validate(), isNull);
      expect(valid.toArguments(), [
        '--resolution',
        '1920x1080',
        '--fps',
        '60',
        '--bitrate',
        '20000',
        '--display-mode',
        'windowed',
        '--video-codec',
        'auto',
        '--video-decoder',
        'auto',
        '--performance-overlay',
        'stream',
        '192.168.1.10',
        'Desktop',
      ]);
    });

    test('trims host and app without joining a shell string', () {
      const config = QualityPreviewConfig(
        host: '  host.example  ',
        app: '  Steam Big Picture ',
        resolution: '2560x1440',
        fps: 120,
        bitrateKbps: 50000,
      );
      expect(config.validate(), isNull);
      expect(config.toArguments().sublist(config.toArguments().length - 2), [
        'host.example',
        'Steam Big Picture',
      ]);
    });

    test('explicit stream options override upstream preferences', () {
      const config = QualityPreviewConfig(
        host: '192.168.1.10',
        app: 'Desktop',
        resolution: '1280x720',
        fps: 30,
        bitrateKbps: 10000,
        videoCodec: 'HEVC',
        videoDecoder: 'hardware',
        displayMode: 'borderless',
        performanceOverlay: false,
      );
      expect(config.validate(), isNull);
      final args = config.toArguments();
      expect(args[args.indexOf('--video-codec') + 1], 'HEVC');
      expect(args[args.indexOf('--video-decoder') + 1], 'hardware');
      expect(args[args.indexOf('--display-mode') + 1], 'borderless');
      expect(args, contains('--no-performance-overlay'));
      expect(
        const QualityPreviewConfig(
          host: 'host',
          app: 'Desktop',
          resolution: '1920x1080',
          fps: 60,
          bitrateKbps: 20000,
          videoDecoder: '--help',
        ).validate(),
        isNotNull,
      );
    });

    test('rejects option-like and malformed values', () {
      expect(
        const QualityPreviewConfig(
          host: '--help',
          app: 'Desktop',
          resolution: '1920x1080',
          fps: 60,
          bitrateKbps: 20000,
        ).validate(),
        isNotNull,
      );
      expect(
        const QualityPreviewConfig(
          host: 'host name',
          app: 'Desktop',
          resolution: '1920x1080',
          fps: 60,
          bitrateKbps: 20000,
        ).validate(),
        isNotNull,
      );
      expect(
        const QualityPreviewConfig(
          host: '127.0.0.1',
          app: '-evil',
          resolution: '1920x1080',
          fps: 60,
          bitrateKbps: 20000,
        ).validate(),
        isNotNull,
      );
      expect(
        const QualityPreviewConfig(
          host: '127.0.0.1',
          app: 'Desktop',
          resolution: '800x600',
          fps: 60,
          bitrateKbps: 20000,
        ).validate(),
        isNotNull,
      );
      expect(
        const QualityPreviewConfig(
          host: '127.0.0.1',
          app: 'Desktop',
          resolution: '1920x1080',
          fps: 45,
          bitrateKbps: 20000,
        ).validate(),
        isNotNull,
      );
      expect(
        const QualityPreviewConfig(
          host: '127.0.0.1',
          app: 'Desktop',
          resolution: '1920x1080',
          fps: 60,
          bitrateKbps: 999999,
        ).validate(),
        isNotNull,
      );
    });

    test('accepts IPv6 and bracketed IPv6 hosts', () {
      for (final host in ['::1', '[::1]', 'fe80::1']) {
        final config = QualityPreviewConfig(
          host: host,
          app: 'Desktop',
          resolution: '1920x1080',
          fps: 60,
          bitrateKbps: 20000,
        );
        expect(config.validate(), isNull, reason: host);
      }
    });

    test('rejects malformed addresses and invalid custom ports', () {
      for (final host in [
        ':',
        '.',
        '[]',
        '999.999.999.999',
        'host..local',
        '-host',
        'host:0',
        'host:65536',
        '[not-ipv6]',
      ]) {
        expect(
          QualityPreviewConfig(
            host: host,
            app: 'Desktop',
            resolution: '1920x1080',
            fps: 60,
            bitrateKbps: 20000,
          ).validate(),
          isNotNull,
          reason: host,
        );
      }
      for (final host in [
        '192.168.1.10:47989',
        '[::1]:47989',
        'host.local',
        'host.local.',
      ]) {
        expect(
          QualityPreviewConfig(
            host: host,
            app: 'Desktop',
            resolution: '1920x1080',
            fps: 60,
            bitrateKbps: 20000,
          ).validate(),
          isNull,
          reason: host,
        );
      }
    });
  });

  group('QualityPreviewLocator', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('yl-quality-locator-');
    });

    tearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    test('finds the installed quality-preview layout', () async {
      final exe = File(
        '${temp.path}${Platform.pathSeparator}client'
        '${Platform.pathSeparator}Moonlight.exe',
      );
      final package = File(
        '${temp.path}${Platform.pathSeparator}quality-preview'
        '${Platform.pathSeparator}windows-x64'
        '${Platform.pathSeparator}moonlight'
        '${Platform.pathSeparator}Moonlight.exe',
      );
      await package.create(recursive: true);

      expect(
        QualityPreviewLocator.findMoonlight(
          executablePath: exe.path,
          workingDirectory: temp.path,
          environment: const {},
        ),
        package.path,
      );
    });

    test('finds Moonlight and Sunshine from the preview root', () async {
      final override = File(
        '${temp.path}${Platform.pathSeparator}moonlight'
        '${Platform.pathSeparator}Moonlight.exe',
      );
      await override.create(recursive: true);
      final sunshine = File(
        '${temp.path}${Platform.pathSeparator}sunshine'
        '${Platform.pathSeparator}sunshine.exe',
      );
      await sunshine.create(recursive: true);

      expect(
        QualityPreviewLocator.findMoonlight(
          executablePath: '${temp.path}${Platform.pathSeparator}missing.exe',
          workingDirectory: temp.path,
          environment: {'YUANLIAN_QUALITY_PREVIEW': temp.path},
        ),
        override.path,
      );
      expect(
        QualityPreviewLocator.findSunshine(
          executablePath: '${temp.path}${Platform.pathSeparator}missing.exe',
          workingDirectory: temp.path,
          environment: const {},
        ),
        sunshine.path,
      );
    });
  });
}
