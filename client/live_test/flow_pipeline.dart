import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:yuanlian_client/src/models/profile.dart';
import 'package:yuanlian_client/src/net/frame_queue.dart';
import 'package:yuanlian_client/src/net/remote_client.dart';
import 'package:yuanlian_client/src/net/server_client.dart';

// Opt-in real I/O test, outside test/ so normal unit tests never contact a host.
// Fixture credentials are passed only in memory/environment, never printed.
void main() {
  test(
    'real flow ticket TLS progressive frame and Flutter JPEG decode',
    () async {
      final env = Platform.environment;
      final api = ServerApi(baseUrl: env['YUANLIAN_TEST_API']!)
        ..token = env['YUANLIAN_TEST_BEARER'];
      final random = Random.secure();
      final nonce = List.generate(
        32,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      final ticket = await api.sessionTicket(
        env['YUANLIAN_TEST_DEVICE']!,
        nonce,
        mode: 'flow',
      );
      final profile = ConnectionProfile(
        name: 'isolated live Host',
        address: env['YUANLIAN_TEST_ADDRESS']!,
        fingerprint: env['YUANLIAN_TEST_FINGERPRINT']!,
        mode: 'flow',
      );
      final client = RemoteClient(
        profile: profile,
        sessionTicket: ticket.ticket,
        sessionNonce: nonce,
      );
      final first = Completer<FrameEvent>();
      final sub = client.events.listen((event) {
        if (event is FrameEvent && !first.isCompleted) first.complete(event);
      });
      try {
        await client.connect();
        final frame = (await first.future.timeout(const Duration(seconds: 12)))
            .frame;
        expect(client.welcome?.mode, 'flow');
        expect(client.welcome?.tileSize, 64);
        expect(client.phase, RemotePhase.ready);
        expect(frame.progressive, true);
        final valid = validateFrame(frame);
        expect(valid.isValid, true);
        final queue = FrameQueue();
        expect(queue.offer(frame, valid, currentGeneration: -1), true);
        final codec = await ui.instantiateImageCodec(
          queue.take()!.frame.tiles.single.jpeg,
        );
        final decoded = await codec.getNextFrame();
        expect(decoded.image.width, frame.tiles.single.width);
        expect(decoded.image.height, frame.tiles.single.height);
        decoded.image.dispose();
        codec.dispose();
      } finally {
        client.dispose();
        await sub.cancel();
        api.dispose();
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
