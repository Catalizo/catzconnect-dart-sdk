import 'dart:convert';

import 'package:catzconnect/src/core/sha256.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> _hex(String h) => fromHex(h.replaceAll(' ', ''))!;

void main() {
  group('SHA-256 (FIPS 180-4 examples)', () {
    test('empty string', () {
      expect(toHex(sha256(<int>[])), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    });
    test('"abc"', () {
      expect(toHex(sha256(utf8.encode('abc'))), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    });
    test('448-bit message', () {
      expect(
        toHex(sha256(utf8.encode('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'))),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
      );
    });
    test('896-bit message', () {
      expect(
        toHex(sha256(utf8.encode('abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqr'
            'lmnopqrsmnopqrstnopqrstu'))),
        'cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1',
      );
    });
    test('one million "a"', () {
      expect(
        toHex(sha256(List<int>.filled(1000000, 0x61))),
        'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
      );
    });
    test('block-boundary lengths (55, 56, 64 bytes)', () {
      expect(toHex(sha256(List<int>.filled(55, 0x61))),
          '9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318');
      expect(toHex(sha256(List<int>.filled(56, 0x61))),
          'b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a');
      expect(toHex(sha256(List<int>.filled(64, 0x61))),
          'ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb');
    });
  });

  group('HMAC-SHA256 (RFC 4231)', () {
    test('case 1', () {
      expect(
        toHex(hmacSha256(List<int>.filled(20, 0x0b), utf8.encode('Hi There'))),
        'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7',
      );
    });
    test('case 2', () {
      expect(
        toHex(hmacSha256(utf8.encode('Jefe'), utf8.encode('what do ya want for nothing?'))),
        '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843',
      );
    });
    test('case 3', () {
      expect(
        toHex(hmacSha256(List<int>.filled(20, 0xaa), List<int>.filled(50, 0xdd))),
        '773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe',
      );
    });
    test('case 4', () {
      expect(
        toHex(hmacSha256(_hex('0102030405060708090a0b0c0d0e0f10111213141516171819'), List<int>.filled(50, 0xcd))),
        '82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b',
      );
    });
    test('case 6: key longer than the block size', () {
      expect(
        toHex(hmacSha256(
            List<int>.filled(131, 0xaa), utf8.encode('Test Using Larger Than Block-Size Key - Hash Key First'))),
        '60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54',
      );
    });
    test('case 7: key and data longer than the block size', () {
      expect(
        toHex(hmacSha256(
          List<int>.filled(131, 0xaa),
          utf8.encode('This is a test using a larger than block-size key and a larger than block-size data. '
              'The key needs to be hashed before being used by the HMAC algorithm.'),
        )),
        '9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2',
      );
    });
  });

  group('hex and comparison', () {
    test('fromHex accepts both cases and rejects junk', () {
      expect(fromHex('00ffAB'), <int>[0, 255, 171]);
      expect(fromHex('abc'), isNull);
      expect(fromHex('zz'), isNull);
    });
    test('constantTimeEquals', () {
      expect(constantTimeEquals(<int>[1, 2], <int>[1, 2]), isTrue);
      expect(constantTimeEquals(<int>[1, 2], <int>[1, 3]), isFalse);
      expect(constantTimeEquals(<int>[1, 2], <int>[1]), isFalse);
    });
  });
}
