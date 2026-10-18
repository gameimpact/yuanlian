import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yuanlian_client/src/net/protocol.dart';
import 'package:yuanlian_client/src/net/remote_client.dart';
import 'package:yuanlian_client/src/ui/workspace_page.dart';

import 'fixtures.dart';

Future<WorkspacePageState> _pumpWorkspace(WidgetTester tester) async {
  final client = RemoteClient(profile: testProfile);
  addTearDown(client.dispose);
  await tester.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: WorkspacePage(client: client, profile: testProfile),
    ),
  );
  await tester.pump();
  return tester.state<WorkspacePageState>(find.byType(WorkspacePage));
}

void main() {
  testWidgets('a valid full frame becomes the first paint', (tester) async {
    final state = await _pumpWorkspace(tester);
    expect(state.debugWaitingFirstFrame, isTrue);

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
    expect(state.debugWaitingFirstFrame, isFalse);
    expect(state.debugTileCount, 4);
    expect(state.debugCachedPixels, 16 * 16);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('a JPEG whose real size differs from the declaration is rejected',
      (tester) async {
    final state = await _pumpWorkspace(tester);

    await tester.runAsync(() async {
      // Metadata claims 8x8 but the JPEG decodes to 1x1.
      state.debugHandleFrame(fullFrame(jpeg1x1));
      for (var attempt = 0; attempt < 100; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        if (state.debugPendingFrames == 0 && state.debugTileCount == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          break;
        }
      }
    });
    await tester.pump();
    expect(state.debugWaitingFirstFrame, isTrue);
    expect(state.debugTileCount, 0);
    expect(state.debugCachedPixels, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('out-of-bounds tile metadata is rejected before decoding',
      (tester) async {
    final state = await _pumpWorkspace(tester);
    final invalid = FrameMessage(
      seq: 1,
      generation: 1,
      full: false,
      width: 16,
      height: 16,
      tiles: [tileAt(12, 0, jpeg8)],
    );
    state.debugHandleFrame(invalid);
    await tester.pump();
    expect(state.debugFrameFault, contains('边界'));
    expect(state.debugPendingFrames, 0);
    expect(state.debugWaitingFirstFrame, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
