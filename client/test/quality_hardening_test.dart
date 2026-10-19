import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yuanlian_client/src/platform/quality_apps.dart';
import 'package:yuanlian_client/src/platform/quality_integrity.dart';
import 'package:yuanlian_client/src/platform/quality_native_process.dart';
import 'package:yuanlian_client/src/platform/quality_preview.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('fixed component integrity', () {
    late Directory root;
    late String executable;
    late List<Map<String, Object>> files;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('yl-integrity-');
      executable = '${root.path}${Platform.pathSeparator}Moonlight.exe';
      await File(executable).writeAsString('abc');
      files = [
        {
          'path': 'Moonlight.exe',
          'size': 3,
          'sha256': sha256.convert(utf8.encode('abc')).toString(),
        },
      ];
    });
    tearDown(() async => root.delete(recursive: true));
    test('preserves and never hashes runtime pairing state', () async {
      final state = File('${root.path}${Platform.pathSeparator}Moonlight.ini');
      await state.writeAsString('synthetic-private-state');
      await QualityIntegrity.verifyFiles(executable, files);
      expect(await state.readAsString(), 'synthetic-private-state');
      final nested = File(
        '${root.path}${Platform.pathSeparator}Moonlight Game Streaming Project${Platform.pathSeparator}Moonlight.ini',
      );
      await nested.parent.create();
      await nested.writeAsString('synthetic-pairing-state');
      await QualityIntegrity.verifyFiles(executable, files);
      expect(await nested.readAsString(), 'synthetic-pairing-state');
    });
    test('same-length executable tampering is rejected', () async {
      await File(executable).writeAsString('bad');
      await expectLater(
        QualityIntegrity.verifyFiles(executable, files),
        throwsA(isA<QualityIntegrityException>()),
      );
    });
    test('missing dependency and unexpected DLL cannot be launched', () async {
      final extended = [
        ...files,
        {'path': 'required.dll', 'size': 3, 'sha256': files.first['sha256']!},
      ];
      await expectLater(
        QualityIntegrity.verifyFiles(executable, extended),
        throwsA(isA<QualityIntegrityException>()),
      );
      await File('${root.path}${Platform.pathSeparator}unexpected.dll')
          .writeAsString('abc');
      await expectLater(
        QualityIntegrity.verifyFiles(executable, files),
        throwsA(isA<QualityIntegrityException>()),
      );
    });
    test('manifest cannot escape the component directory', () async {
      final traversal = [
        {'path': '../outside.exe', 'size': 3, 'sha256': files.first['sha256']!},
      ];
      await expectLater(
        QualityIntegrity.verifyFiles(executable, traversal),
        throwsA(isA<QualityIntegrityException>()),
      );
    });
  });

  final moonlight = Platform.isWindows
      ? QualityPreviewLocator.findMoonlight(
          workingDirectory: Directory.current.parent.path,
        )
      : null;
  test(
    'bundled trusted manifest verifies actual pinned component files',
    () async {
      await QualityIntegrity.verify(moonlight!);
    },
    skip: moonlight == null,
  );

  const header =
      'Name, ID, HDR Support, App Collection Game, Hidden, Direct Launch, Boxart URL\n';
  test('parses real CLI CSV format, including commas and non-ASCII names', () {
    final apps = QualityAppQuery.parseCsv(
      '$header"Desktop",1,false,false,false,true,""\n"中文, Apps",2,true,false,false,false,"ignored"\n',
    );
    expect(apps.map((app) => app.name), ['Desktop', '中文, Apps']);
    expect(apps.last.hdr, isTrue);
    expect(QualityAppQuery.parseCsv(header), isEmpty);
  });
  test('rejects truncated, ambiguous, option-like and oversized app lists', () {
    for (final text in [
      'unexpected data',
      '$header"Desktop,1,false,false,false,true,""',
      '$header"Desktop",1,false,false,false,true,""\n"Desktop",2,false,false,false,true,""',
      '$header"--help",1,false,false,false,true,""',
      List.filled(65537, 'x').join(),
    ]) {
      expect(
        () => QualityAppQuery.parseCsv(text),
        throwsA(isA<QualityAppsException>()),
      );
    }
  });

  test(
    'native process is released after exit and does not expose stream output',
    () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeQualityChild.channel, (call) async {
            calls.add(call.method);
            if (call.method == 'start') return {'id': 1, 'pid': 123};
            if (call.method == 'poll') {
              return {
                'running': false,
                'exitCode': 0,
                'output': '',
                'overflow': false,
              };
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(NativeQualityChild.channel, null),
      );
      final child = await NativeQualityChild.start(
        'C:\\fixed\\Moonlight.exe',
        const [],
      );
      expect(await child.exitCode, 0);
      expect(calls, ['start', 'poll', 'release']);
      expect(await child.stdout.toList(), isEmpty);
    },
  );

  test('missing native supervisor fails closed without falling back to Process.start', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeQualityChild.channel, null);
    await expectLater(
      NativeQualityChild.start('C:\\fixed\\Moonlight.exe', const []),
      throwsA(isA<MissingPluginException>()),
    );
  });

  for (final cancel in [false, true]) {
    test(
      cancel
          ? 'cancelled app query terminates and releases its child'
          : 'timed-out app query terminates and releases its child',
      () async {
        final query = QualityAppQuery();
        final calls = <String>[];
        var stopped = false;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(NativeQualityChild.channel, (call) async {
              calls.add(call.method);
              if (call.method == 'start') {
                expect((call.arguments as Map)['capture'], isTrue);
                if (cancel) query.cancel();
                return {'id': 2, 'pid': 234};
              }
              if (call.method == 'stop') {
                stopped = true;
                return true;
              }
              if (call.method == 'poll') {
                return stopped
                    ? {
                        'running': false,
                        'exitCode': 1,
                        'output': '',
                        'overflow': false,
                      }
                    : {'running': true};
              }
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(NativeQualityChild.channel, null),
        );
        await expectLater(
          query.load(
            moonlight!,
            '127.0.0.1',
            timeout: const Duration(milliseconds: 50),
          ),
          throwsA(
            isA<QualityAppsException>().having(
              (error) => error.message,
              'reason',
              contains(cancel ? '取消' : '超时'),
            ),
          ),
        );
        expect(stopped, isTrue);
        expect(calls, contains('release'));
      },
      skip: moonlight == null,
    );
  }
}
