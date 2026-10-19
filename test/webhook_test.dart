// Webhook signatures and the push user_hash against the TypeScript SDK.

import 'dart:convert';

import 'package:catzconnect/catzconnect.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/host_sodium.dart';

void main() {
  final Map<String, dynamic> v = loadVectors();

  group('verifyWebhookSignature', () {
    final List<Object?> cases = v['webhook'] as List<Object?>;
    for (int i = 0; i < cases.length; i++) {
      final Map<String, dynamic> c = cases[i]! as Map<String, dynamic>;
      test('#$i ${c['result']}', () {
        final bool got = verifyWebhookSignature(
          c['body'] as String,
          c['header'] as String,
          c['secret'] as String,
          toleranceSeconds: c['tolerance'] as int,
          nowSeconds: c['now'] as int,
        );
        expect(got, c['result']);
        // The same body as bytes gives the same answer.
        expect(
          verifyWebhookSignature(utf8.encode(c['body'] as String), c['header'] as String, c['secret'] as String,
              toleranceSeconds: c['tolerance'] as int, nowSeconds: c['now'] as int),
          c['result'],
        );
      });
    }

    test('a null header is false', () {
      expect(verifyWebhookSignature('{}', null, 'whsec_x'), isFalse);
    });
  });

  test('computeUserHash', () {
    for (final Object? raw in v['user_hash'] as List<Object?>) {
      final Map<String, dynamic> c = raw! as Map<String, dynamic>;
      expect(computeUserHash(c['external_user_id'] as String, c['secret'] as String), c['hash']);
    }
    expect(
      () => computeUserHash('u', ''),
      throwsA(isA<ArgumentError>().having((ArgumentError e) => e.message, 'message', v['user_hash_error'])),
    );
  });

  test('isSealedPush', () {
    final Map<String, dynamic> push = v['push'] as Map<String, dynamic>;
    for (final Object? raw in push['is_sealed'] as List<Object?>) {
      final Map<String, dynamic> c = raw! as Map<String, dynamic>;
      expect(isSealedPush(c['data'] as Map<String, dynamic>), c['result']);
    }
    expect(isSealedPush(null), isFalse);
  });
}
