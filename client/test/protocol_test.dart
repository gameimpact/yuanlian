import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yuanlian_client/src/net/bincode.dart';
import 'package:yuanlian_client/src/net/protocol.dart';
import 'package:yuanlian_client/src/net/remote_client.dart';

void main() {
  test('decodes file capabilities, listing and transfer messages', () {
    final cap = ByteWriter()
      ..u32(6)
      ..boolean(true)
      ..string('file-root')
      ..boolean(true)
      ..boolean(false)
      ..boolean(false);
    final capMessage =
        decodeServerMessage(cap.toBytes()) as FileCapabilitiesReceived;
    expect(capMessage.enabled, true);
    expect(capMessage.rootLabel, 'file-root');
    expect(capMessage.read, true);
    expect(capMessage.write, false);
    expect(capMessage.delete, false);

    final listing = ByteWriter()
      ..u32(7)
      ..u64(5)
      ..string('sub')
      ..u64(1)
      ..string('a.txt')
      ..string('sub/a.txt')
      ..boolean(false)
      ..u64(12)
      ..u64(1700000000000);
    final listingMessage =
        decodeServerMessage(listing.toBytes()) as DirListingReceived;
    expect(listingMessage.requestId, 5);
    expect(listingMessage.path, 'sub');
    expect(listingMessage.entries.single.path, 'sub/a.txt');
    expect(listingMessage.entries.single.size, 12);

    final chunk = ByteWriter()
      ..u32(8)
      ..u64(9)
      ..u64(0)
      ..bytes(Uint8List.fromList([1, 2, 3]));
    final chunkMessage =
        decodeServerMessage(chunk.toBytes()) as FileChunkReceived;
    expect(chunkMessage.taskId, 9);
    expect(chunkMessage.data, [1, 2, 3]);

    final done = ByteWriter()
      ..u32(10)
      ..u64(9)
      ..string('a.txt')
      ..u64(3)
      ..string('abc');
    final doneMessage = decodeServerMessage(done.toBytes()) as FileDoneReceived;
    expect(doneMessage.sha256, 'abc');

    final error = ByteWriter()
      ..u32(11)
      ..u64(5)
      ..u64(0)
      ..string('denied');
    final errorMessage =
        decodeServerMessage(error.toBytes()) as FileErrorReceived;
    expect(errorMessage.message, 'denied');
  });

  test('encodes file client messages with appended enum tags', () {
    final list = ByteReader(encodeFileList(1, 'sub'));
    expect(list.u32(), 5);
    expect(list.u64(), 1);
    expect(list.string(), 'sub');

    final start = ByteReader(encodeUploadStart(2, 'a.txt', 3, true));
    expect(start.u32(), 7);
    expect(start.u64(), 2);
    expect(start.string(), 'a.txt');
    expect(start.u64(), 3);
    expect(start.boolean(), true);

    final chunk = ByteReader(
      encodeUploadChunk(2, 0, Uint8List.fromList([9, 8])),
    );
    expect(chunk.u32(), 8);
    expect(chunk.u64(), 2);
    expect(chunk.u64(), 0);
    expect(chunk.bytes(), [9, 8]);

    final finish = ByteReader(encodeUploadFinish(2));
    expect(finish.u32(), 9);
    expect(finish.u64(), 2);
  });

  test('decodes Welcome exactly as the Rust Host encodes it', () {
    final writer = ByteWriter()
      ..u32(0)
      ..u16(protocolVersion)
      ..string('host-1')
      ..string('测试主机')
      ..u32(3200)
      ..u32(2000)
      ..boolean(true)
      ..string('tiles')
      ..u32(128)
      ..boolean(true)
      ..string('alice')
      ..u32(permissionView | permissionControl)
      ..string('ticket')
      ..string('session-1')
      ..u64(1700003600);
    final message = decodeServerMessage(writer.toBytes());
    expect(message, isA<WelcomeReceived>());
    final welcome = (message as WelcomeReceived).welcome;
    expect(welcome.protocolVersion, protocolVersion);
    expect(welcome.hostName, '测试主机');
    expect(welcome.screenWidth, 3200);
    expect(welcome.screenHeight, 2000);
    expect(welcome.inputAllowed, true);
    expect(welcome.tileSize, 128);
    expect(welcome.authenticated, true);
    expect(welcome.account, 'alice');
    expect(welcome.permissions, permissionView | permissionControl);
    expect(welcome.authMode, 'ticket');
    expect(welcome.sessionId, 'session-1');
    expect(welcome.ticketExpiresAt, 1700003600);
  });

  test('decodes a frame with tiles', () {
    final jpeg = Uint8List.fromList([1, 2, 3, 4]);
    final writer = ByteWriter()
      ..u32(1)
      ..u64(42)
      ..u32(3)
      ..boolean(true)
      ..u32(640)
      ..u32(480)
      ..u64(1)
      ..u32(128)
      ..u32(0)
      ..u32(128)
      ..u32(128)
      ..bytes(jpeg);
    final message = decodeServerMessage(writer.toBytes()) as FrameReceived;
    expect(message.frame.seq, 42);
    expect(message.frame.generation, 3);
    expect(message.frame.full, true);
    expect(message.frame.tiles.single.x, 128);
    expect(message.frame.tiles.single.jpeg, jpeg);
  });

  test('decodes errors and rejects trailing bytes', () {
    final writer = ByteWriter()
      ..u32(4)
      ..u32(ErrorCode.inputDenied.index)
      ..string('denied');
    final message = decodeServerMessage(writer.toBytes()) as HostError;
    expect(message.code, ErrorCode.inputDenied);
    expect(message.message, 'denied');

    final broken = Uint8List.fromList([...writer.toBytes(), 0]);
    expect(
      () => decodeServerMessage(broken),
      throwsA(isA<ProtocolException>()),
    );
  });

  test('client hello and input messages use the Rust enum layout', () {
    final hello = ByteReader(
      encodeHello(clientName: 'viewer', clientId: 'id', requestInput: true),
    );
    expect(hello.u32(), 0);
    expect(hello.u16(), protocolVersion);
    expect(hello.string(), 'viewer');
    expect(hello.string(), 'id');
    expect(hello.boolean(), true);
    expect(
      hello.u32(),
      featureFileTransfer | featureTextInput | featureSessionTicket,
    );
    expect(hello.boolean(), false);
    expect(hello.string(), '');
    expect(hello.string(), 'tiles');
    expect(hello.string(), '');
    expect(hello.remaining, 0);

    final nonce = 'ab' * 32;
    final ticketed = ByteReader(
      encodeHello(
        clientName: 'viewer',
        clientId: 'id',
        requestInput: true,
        sessionTicket: 'yl1.payload.signature',
        sessionNonce: nonce,
      ),
    );
    expect(ticketed.u32(), 0);
    expect(ticketed.u16(), protocolVersion);
    ticketed
      ..string()
      ..string()
      ..boolean();
    ticketed.u32();
    expect(ticketed.boolean(), true);
    expect(ticketed.string(), 'yl1.payload.signature');
    expect(ticketed.string(), nonce);
    expect(ticketed.string(), 'tiles');
    expect(ticketed.string(), '');
    expect(ticketed.remaining, 0);

    final move = ByteReader(encodeMouseMove(10, 20));
    expect(move.u32(), 1);
    expect(move.u32(), 0);
    expect(move.i32(), 10);
    expect(move.i32(), 20);

    final key = ByteReader(encodeKey(0x41, true, true));
    expect(key.u32(), 1);
    expect(key.u32(), 3);
    expect(key.u16(), 0x41);
    expect(key.boolean(), true);
    expect(key.boolean(), true);
  });

  test('encodes Unicode text as a TextInput message', () {
    final reader = ByteReader(encodeTextInput('远联 😀'));
    expect(reader.u32(), 11);
    expect(reader.string(), '远联 😀');
    expect(reader.remaining, 0);
  });

  test('framing uses big-endian length prefix', () {
    final payload = encodeRequestKeyframe();
    final framed = framePayload(payload);
    expect(
      ByteData.sublistView(framed, 0, 4).getUint32(0, Endian.big),
      payload.length,
    );
    expect(framed.sublist(4), payload);
  });

  test('fingerprint parsing accepts separators and rejects bad lengths', () {
    final raw = parseFingerprint(
      'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:'
      'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99',
    );
    expect(raw.length, 32);
    expect(raw.first, 0xAA);
    expect(() => parseFingerprint('abc'), throwsFormatException);
  });

  test('quality endpoint includes effective authorization without pretending first frame', () {
    final writer = ByteWriter()
      ..u32(12)
      ..u16(48189)
      ..string('public-cert')
      ..string('host-uuid')
      ..u32(1)
      ..boolean(false);
    final ready = decodeServerMessage(writer.toBytes()) as QualityReadyReceived;
    expect(ready.port, 48189);
    expect(ready.permissions, permissionView);
    expect(ready.inputAllowed, false);
  });
}
