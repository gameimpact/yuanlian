import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yuanlian_client/src/net/remote_client.dart';
import 'package:yuanlian_client/src/platform/credential_store.dart';
import 'package:yuanlian_client/src/ui/account_page.dart';
import 'package:yuanlian_client/src/ui/file_browser_page.dart';
import 'package:yuanlian_client/src/ui/home_page.dart';
import 'package:yuanlian_client/src/ui/home_shell.dart';
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

  testWidgets('Android account page fits 360dp at 1.3 text scale',
      (tester) async {
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
  });

  testWidgets('Windows workspace fits 1280x800 with a live frame',
      (tester) async {
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

  testWidgets('Android workspace fits 360dp at 1.3 text scale with a live frame',
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
    testWidgets(
      'file transfer in progress fits ${scenario.$1.width.toInt()}px '
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
          message: '上传 report.pdf：3.2 MiB / 8.0 MiB',
          progress: 0.4,
          success: false,
          busy: true,
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.textContaining('上传 report.pdf'), findsOneWidget);
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
      },
    );

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
}
