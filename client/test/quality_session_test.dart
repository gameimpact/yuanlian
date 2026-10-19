import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:yuanlian_client/src/platform/quality_preview.dart';
import 'package:yuanlian_client/src/platform/quality_session.dart';
import 'package:yuanlian_client/src/ui/quality_preview_page.dart';
import 'package:yuanlian_client/src/ui/theme.dart';

class _Child implements Process {
  final completion = Completer<int>();
  final out = StreamController<List<int>>();
  final err = StreamController<List<int>>();
  bool acceptsKill = true;
  int kills = 0;
  @override
  int get pid => 4321;
  @override
  Future<int> get exitCode => completion.future;
  @override
  Stream<List<int>> get stdout => out.stream;
  @override
  Stream<List<int>> get stderr => err.stream;
  @override
  IOSink get stdin => throw UnsupportedError('stdin is not used');
  void finish(int code) {
    if (!completion.isCompleted) completion.complete(code);
    unawaited(out.close());
    unawaited(err.close());
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    kills++;
    if (acceptsKill) finish(0);
    return acceptsKill;
  }
}

void main() {
  testWidgets('leaving a running preview requires stopping its owned child', (
    tester,
  ) async {
    final child = _Child();
    final session = QualitySession(starter: (_, _) async => child);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => QualityPreviewPage(session: session),
                ),
              ),
              child: const Text('open preview'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open preview'));
    await tester.pumpAndSettle();
    await session.start('Moonlight.exe', const []);
    await tester.pump();
    expect(find.text('Moonlight 串流客户端进程运行中'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('结束本页启动的 Moonlight？'), findsOneWidget);
    await tester.tap(find.text('留在此页'));
    await tester.pumpAndSettle();
    expect(child.kills, 0);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('结束并返回'));
    await tester.pumpAndSettle();
    expect(child.kills, 1);
    expect(find.byType(QualityPreviewPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  final moonlight = Platform.isWindows
      ? QualityPreviewLocator.findMoonlight(
          workingDirectory: Directory.current.parent.path,
        )
      : null;
  test(
    'pinned Moonlight accepts the extended CLI without starting a stream',
    () async {
      final session = QualitySession(starter: (exe, args) => Process.start(exe, args));
      addTearDown(session.dispose);
      const config = QualityPreviewConfig(
        host: '127.0.0.1',
        app: 'Desktop',
        resolution: '1280x720',
        fps: 30,
        bitrateKbps: 10000,
        videoCodec: 'HEVC',
        videoDecoder: 'hardware',
      );
      await session.start(moonlight!, [...config.toArguments(), '--help']);
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (session.busy && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(session.busy, isFalse);
      expect(session.exitCode, 0);
    },
    skip: moonlight == null,
  );

  test('rejects a second launch while the first start is pending', () async {
    final pending = Completer<Process>();
    final child = _Child();
    final session = QualitySession(starter: (_, _) => pending.future);
    final first = session.start('Moonlight.exe', const []);
    expect(session.busy, isTrue);
    await expectLater(
      session.start('Moonlight.exe', const []),
      throwsStateError,
    );
    pending.complete(child);
    await first;
    expect(child.out.hasListener, isTrue);
    expect(child.err.hasListener, isTrue);
    await session.stop();
    expect(session.busy, isFalse);
    expect(session.state, QualityProcessState.exited);
    expect(child.kills, 1);
    session.dispose();
  });

  test(
    'abnormal exit becomes failure, not a successful video connection',
    () async {
      final child = _Child();
      final session = QualitySession(starter: (_, _) async => child);
      await session.start('Moonlight.exe', const ['stream']);
      child.finish(17);
      await Future<void>.delayed(Duration.zero);
      expect(session.exitCode, 17);
      expect(session.state, QualityProcessState.failed);
      expect(session.busy, isFalse);
      expect(session.error, contains('17'));
      session.dispose();
    },
  );

  test(
    'dispose during start ends the late child without notifying disposed UI',
    () async {
      final pending = Completer<Process>();
      final child = _Child();
      final session = QualitySession(starter: (_, _) => pending.future);
      final starting = session.start('Moonlight.exe', const []);
      session.dispose();
      pending.complete(child);
      await starting;
      expect(child.kills, 1);
    },
  );

  test('failed termination keeps the child owned and allows retry', () async {
    final child = _Child()..acceptsKill = false;
    final session = QualitySession(starter: (_, _) async => child);
    await session.start('Moonlight.exe', const []);
    await session.stop();
    expect(session.busy, isTrue);
    expect(session.pid, 4321);
    expect(session.error, isNotNull);
    child.acceptsKill = true;
    await session.stop();
    expect(session.busy, isFalse);
    session.dispose();
  });

  test(
    'launch exceptions are reported without echoing upstream details',
    () async {
      final session = QualitySession(
        starter: (_, _) async {
          throw ProcessException('path', [], 'private upstream output');
        },
      );
      await session.start('Moonlight.exe', const []);
      expect(session.state, QualityProcessState.failed);
      expect(session.error, isNot(contains('private')));
      expect(session.busy, isFalse);
      session.dispose();
    },
  );

  test(
    'real child with full stdout/stderr exits without blocking on pipes',
    () async {
      final session = QualitySession(
        starter: (_, _) => Process.start(
          Platform.isWindows ? 'powershell.exe' : '/bin/sh',
          Platform.isWindows
              ? [
                  '-NoProfile',
                  '-NonInteractive',
                  '-Command',
                  "[Console]::Out.Write('x' * 1048576); [Console]::Error.Write('y' * 1048576); exit 7",
                ]
              : [
                  '-c',
                  'head -c 1048576 /dev/zero; head -c 1048576 /dev/zero >&2; exit 7',
                ],
        ),
      );
      await session.start('pipe-test', const []);
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (session.busy && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(session.busy, isFalse);
      expect(session.exitCode, 7);
      session.dispose();
    },
  );
}
