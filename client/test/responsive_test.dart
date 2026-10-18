import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yuanlian_client/src/models/profile.dart';
import 'package:yuanlian_client/src/net/remote_client.dart';
import 'package:yuanlian_client/src/ui/file_browser_page.dart';
import 'package:yuanlian_client/src/ui/home_page.dart';
import 'package:yuanlian_client/src/ui/theme.dart';
import 'package:yuanlian_client/src/ui/workspace_page.dart';

const _profile = ConnectionProfile(
  name: '布局测试 Host',
  address: '127.0.0.1:24800',
  fingerprint:
      'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:'
      'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99',
);

Future<void> _pumpAt(
  WidgetTester tester,
  Size size,
  Widget child, {
  double textScale = 1.0,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light),
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

void main() {
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
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('workspace fits 360dp at 1.3 text scale', (tester) async {
    final client = RemoteClient(profile: _profile);
    addTearDown(client.dispose);
    await _pumpAt(
      tester,
      const Size(360, 800),
      WorkspacePage(client: client, profile: _profile),
      textScale: 1.3,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('file page fits 360dp and 1280px', (tester) async {
    final client = RemoteClient(profile: _profile);
    addTearDown(client.dispose);
    await _pumpAt(
      tester,
      const Size(360, 800),
      FileBrowserPage(client: client),
      textScale: 1.3,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
