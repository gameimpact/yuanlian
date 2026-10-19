import 'package:yuanlian_client/src/models/profile.dart';
import 'package:yuanlian_client/src/models/session_auth.dart';
import 'package:yuanlian_client/src/ui/quality_broker_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yuanlian_client/src/net/remote_client.dart';
import 'package:yuanlian_client/src/platform/credential_store.dart';
import 'package:yuanlian_client/src/ui/account_page.dart';
import 'package:yuanlian_client/src/ui/file_browser_page.dart';
import 'package:yuanlian_client/src/ui/home_page.dart';
import 'package:yuanlian_client/src/ui/home_shell.dart';
import 'package:yuanlian_client/src/ui/quality_preview_page.dart';
import 'package:yuanlian_client/src/ui/theme.dart';
import 'package:yuanlian_client/src/ui/workspace_page.dart';

import 'fixtures.dart';

Future<void> _pumpAt(
  WidgetTester tester,
  Size size,
  Widget child, {
  double textScale = 1.0,
  TargetPlatform platform = TargetPlatform.windows,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light).copyWith(platform: platform),
      builder: (context, appChild) {
        final query = MediaQuery.of(context);
        return MediaQuery(
          data: query.copyWith(
            size: size,
            textScaler: TextScaler.linear(textScale),
          ),
          child: appChild ?? const SizedBox.shrink(),
        );
      },
      home: child,
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _settleIo(WidgetTester tester) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) {
      return;
    }
  }
}

void main() {
  setUp(() => CredentialStore.debugUseMemory = true);
  tearDown(() => CredentialStore.debugUseMemory = false);

  testWidgets('Windows account page fits 1280x800', (tester) async {
    await _pumpAt(
      tester,
      const Size(1280, 800),
      AccountPage(onConnected: (_) {}),
      platform: TargetPlatform.windows,
    );
    await _settleIo(tester);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('连接控制服务端'), findsOneWidget);
  });

  testWidgets('Android account page fits 360dp at 1.3 text scale', (
    tester,
  ) async {
    await _pumpAt(
      tester,
      const Size(360, 800),
      AccountPage(onConnected: (_) {}),
      textScale: 1.3,
      platform: TargetPlatform.android,
    );
    await _settleIo(tester);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('连接控制服务端'), findsOneWidget);
  });

  testWidgets('Windows quality preview fits 1280x800', (tester) async {
    await _pumpAt(
      tester,
      const Size(1280, 800),
      const QualityPreviewPage(),
      platform: TargetPlatform.windows,
    );
    await _settleIo(tester);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Moonlight 社区预览'), findsWidgets);
    expect(find.textContaining('安全边界'), findsOneWidget);
    expect(find.text('质量模式使用视频串流'), findsOneWidget);
    final launch = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '启动 Moonlight 串流'),
    );
    expect(launch.onPressed, isNull);
    final host = tester
        .widgetList<TextField>(find.byType(TextField))
        .singleWhere(
          (field) => field.decoration?.labelText == 'Sunshine Host 地址',
        );
    expect(host.controller!.text, isEmpty);
  });

  testWidgets('Android quality preview fits 360dp at 1.3 text scale', (
    tester,
  ) async {
    await _pumpAt(
      tester,
      const Size(360, 800),
      const QualityPreviewPage(),
      textScale: 1.3,
      platform: TargetPlatform.android,
    );
    await _settleIo(tester);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Moonlight 社区预览'), findsWidgets);
  });

  testWidgets('Windows HomeShell fits 1280x800', (tester) async {
    await _pumpAt(
      tester,
      const Size(1280, 800),
      HomeShell(themeMode: ThemeMode.light, onThemeModeChanged: (_) {}),
      platform: TargetPlatform.windows,
    );
    await _settleIo(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('Android HomeShell fits 360dp at 1.3 text scale', (tester) async {
    await _pumpAt(
      tester,
      const Size(360, 800),
      HomeShell(themeMode: ThemeMode.light, onThemeModeChanged: (_) {}),
      textScale: 1.3,
      platform: TargetPlatform.android,
    );
    await _settleIo(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('Windows home fits 1280x800', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await _pumpAt(
      tester,
      const Size(1280, 800),
      HomePage(
        profiles: const [],
        onConnect: (_) {},
        onRemove: (_) async {},
        addressFocusNode: focus,
      ),
      platform: TargetPlatform.windows,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact home fits 360dp at 1.3 text scale', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await _pumpAt(
      tester,
      const Size(360, 800),
      HomePage(
        profiles: const [],
        onConnect: (_) {},
        onRemove: (_) async {},
        addressFocusNode: focus,
        compact: true,
        showHeader: false,
      ),
      textScale: 1.3,
      platform: TargetPlatform.android,
    );
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('模式与开发计划'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('模式与开发计划'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('打开预览'), findsOneWidget);
  });

  testWidgets('Windows workspace fits 1280x800 with a live frame', (
    tester,
  ) async {
    final client = RemoteClient(profile: testProfile);
    addTearDown(client.dispose);
    await _pumpAt(
      tester,
      const Size(1280, 800),
      WorkspacePage(client: client, profile: testProfile),
      platform: TargetPlatform.windows,
    );
    final state = tester.state<WorkspacePageState>(find.byType(WorkspacePage));
    await tester.runAsync(() async {
      state.debugHandleFrame(fullFrame(jpeg8));
      for (var attempt = 0; attempt < 100; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        if (!state.debugWaitingFirstFrame) {
          break;
        }
      }
    });
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(state.debugTileCount, 4);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
    'Android workspace fits 360dp at 1.3 text scale with a live frame',
    (tester) async {
      final client = RemoteClient(profile: testProfile);
      addTearDown(client.dispose);
      await _pumpAt(
        tester,
        const Size(360, 800),
        WorkspacePage(client: client, profile: testProfile),
        textScale: 1.3,
        platform: TargetPlatform.android,
      );
      final state = tester.state<WorkspacePageState>(
        find.byType(WorkspacePage),
      );
      await tester.runAsync(() async {
        state.debugHandleFrame(fullFrame(jpeg8));
        for (var attempt = 0; attempt < 100; attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          if (!state.debugWaitingFirstFrame) {
            break;
          }
        }
      });
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(state.debugTileCount, 4);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('Android file page fits 360dp at 1.3 text scale', (tester) async {
    final client = RemoteClient(profile: testProfile);
    addTearDown(client.dispose);
    await _pumpAt(
      tester,
      const Size(360, 800),
      FileBrowserPage(client: client),
      textScale: 1.3,
      platform: TargetPlatform.android,
    );
    await _settleIo(tester);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Host 未配置'), findsOneWidget);
  });

  testWidgets('Windows file page fits 1280x800', (tester) async {
    final client = RemoteClient(profile: testProfile);
    addTearDown(client.dispose);
    await _pumpAt(
      tester,
      const Size(1280, 800),
      FileBrowserPage(client: client),
      platform: TargetPlatform.windows,
    );
    await _settleIo(tester);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Host 未配置'), findsOneWidget);
  });

  for (final scenario in <(Size, TargetPlatform, double)>[
    (const Size(360, 800), TargetPlatform.android, 1.3),
    (const Size(1280, 800), TargetPlatform.windows, 1.0),
  ]) {
    testWidgets('file transfer in progress fits ${scenario.$1.width.toInt()}px '
        'on ${scenario.$2.name}', (tester) async {
      final client = RemoteClient(profile: testProfile)
        ..fileEnabled = true
        ..fileRootLabel = 'shared';
      addTearDown(client.dispose);
      await _pumpAt(
        tester,
        scenario.$1,
        FileBrowserPage(client: client),
        textScale: scenario.$3,
        platform: scenario.$2,
      );
      await _settleIo(tester);
      final state = tester.state<FileBrowserPageState>(
        find.byType(FileBrowserPage),
      );
      state.debugSetTransfer(
        message: '上传 report.pdf：3.2 MiB / 8.0 MiB',
        progress: 0.4,
        success: false,
        busy: true,
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('上传 report.pdf'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });

    testWidgets(
      'file transfer failure state fits ${scenario.$1.width.toInt()}px '
      'on ${scenario.$2.name}',
      (tester) async {
        final client = RemoteClient(profile: testProfile)
          ..fileEnabled = true
          ..fileRootLabel = 'shared';
        addTearDown(client.dispose);
        await _pumpAt(
          tester,
          scenario.$1,
          FileBrowserPage(client: client),
          textScale: scenario.$3,
          platform: scenario.$2,
        );
        await _settleIo(tester);
        final state = tester.state<FileBrowserPageState>(
          find.byType(FileBrowserPage),
        );
        state.debugSetTransfer(
          message: '下载失败：目标磁盘空间不足',
          progress: 0.7,
          success: false,
          busy: false,
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.textContaining('下载失败'), findsOneWidget);
      },
    );
  }

  for (final size in [const Size(1280, 800), const Size(360, 800)]) {
    testWidgets('ticket quality broker fits ${size.width} at 1.3 text', (
      tester,
    ) async {
      await _pumpAt(
        tester,
        size,
        const QualityBrokerPage(
          profile: ConnectionProfile(
            name: 'Host',
            address: '127.0.0.1:24800',
            fingerprint: '',
            mode: 'quality',
          ),
          auth: SessionAuth(
            ticket: 'fixture-only',
            nonce: '',
            sessionId: 'test',
            account: 'test',
            permissions: 1,
            expiresAt: 0,
          ),
        ),
        textScale: 1.3,
        platform: size.width < 400
            ? TargetPlatform.android
            : TargetPlatform.windows,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('使用票据连接质量串流'), findsOneWidget);
    });
  }
}
