import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jph_real_estate_hr/core/windows_updater.dart';
import 'package:pinenacl/ed25519.dart' as nacl;

// A manifest signed by `openssl pkeyutl -sign -rawin` — exactly how the release pipeline signs.
// (Throw-away test key: its private half was never kept.)
const _opensslPub = 'uWxMm9hGcfqFSn9Of5EbDRtp9UsWE27Gls8hYohyDis=';
const _opensslText =
    '{"app":"VALUNIVO","platform":"windows-x64","channel":"stable","version":"1.0.7","build":7,"installer":"VALUNIVO-Setup-1.0.7.exe","size":19586460,"sha256":"a415e2603594ae2752f1f9277ca7c2025f65a5acdbb87bb6b1cbb598156dbe91","issued":1763240000,"rollback":false}';
const _opensslSig = 'SvpqpYdPwiGzav3eH7lV5zYQX/clJusWWdMb3IE/4wSw6cnCKNOrnZqKw5I98Kqwfv1+NHN6fxzanXqDwGz+DQ==';

String envelope(String text, String sig) => jsonEncode({'format': 1, 'manifest': text, 'sig': sig});

void main() {
  final pub = [base64Decode(_opensslPub)];

  test('accepts a manifest signed by the release pipeline (openssl Ed25519)', () {
    final m = UpdateManifest.verify(envelope(_opensslText, _opensslSig), pub);
    expect(m.build, 7);
    expect(m.version, '1.0.7');
    expect(m.installer, 'VALUNIVO-Setup-1.0.7.exe');
    expect(m.size, 19586460);
    expect(m.rollback, isFalse);
  });

  test('rejects any change to the signed text (e.g. a swapped hash or a higher build)', () {
    final altered = _opensslText.replaceFirst('a415e26', 'b415e26');
    expect(() => UpdateManifest.verify(envelope(altered, _opensslSig), pub), throwsA(anything));
    final bumped = _opensslText.replaceFirst('"build":7', '"build":8');
    expect(() => UpdateManifest.verify(envelope(bumped, _opensslSig), pub), throwsA(anything));
  });

  test('rejects a manifest signed by another key', () {
    final other = nacl.SigningKey.generate();
    final sig = base64Encode(other.sign(utf8.encode(_opensslText)).signature.asTypedList);
    expect(() => UpdateManifest.verify(envelope(_opensslText, sig), pub), throwsA(anything));
  });

  test('rejects unsigned / malformed manifests', () {
    expect(() => UpdateManifest.verify(_opensslText, pub), throwsA(anything)); // plain, no signature
    expect(() => UpdateManifest.verify(envelope(_opensslText, ''), pub), throwsA(anything));
    expect(() => UpdateManifest.verify('not json', pub), throwsA(anything));
    expect(() => UpdateManifest.verify(envelope(_opensslText, _opensslSig), [pub.first.sublist(1)]), throwsA(anything));
  });

  test('a correctly signed manifest with unsafe content is still refused', () {
    final key = nacl.SigningKey.generate();
    final kpub = [key.verifyKey.asTypedList];
    String signed(Map<String, dynamic> m) {
      final t = jsonEncode(m);
      return envelope(t, base64Encode(key.sign(utf8.encode(t)).signature.asTypedList));
    }

    final good = {
      'app': 'VALUNIVO', 'platform': 'windows-x64', 'channel': 'stable', 'version': '1.0.9', 'build': 9,
      'installer': 'VALUNIVO-Setup-1.0.9.exe', 'size': 20000000, 'sha256': 'a' * 64, 'issued': 1, 'rollback': false,
    };
    expect(UpdateManifest.verify(signed(good), kpub).build, 9);
    expect(() => UpdateManifest.verify(signed({...good, 'installer': '..\\evil.exe'}), kpub), throwsA(anything));
    expect(() => UpdateManifest.verify(signed({...good, 'installer': 'setup.ps1'}), kpub), throwsA(anything));
    expect(() => UpdateManifest.verify(signed({...good, 'platform': 'android'}), kpub), throwsA(anything));
    expect(() => UpdateManifest.verify(signed({...good, 'sha256': 'xyz'}), kpub), throwsA(anything));
    expect(() => UpdateManifest.verify(signed({...good, 'size': 12}), kpub), throwsA(anything));
    expect(UpdateManifest.verify(signed({...good, 'rollback': true}), kpub).rollback, isTrue);
  });

  test('planned key rotation: a manifest signed by either trusted key is accepted, any other is not', () {
    final next = nacl.SigningKey.generate();
    final sig = base64Encode(next.sign(utf8.encode(_opensslText)).signature.asTypedList);
    final both = [pub.first, next.verifyKey.asTypedList];
    expect(UpdateManifest.verify(envelope(_opensslText, _opensslSig), both).build, 7); // old key
    expect(UpdateManifest.verify(envelope(_opensslText, sig), both).build, 7); // new key
    expect(() => UpdateManifest.verify(envelope(_opensslText, sig), pub), throwsA(anything)); // new key not trusted yet
    expect(() => UpdateManifest.verify(envelope(_opensslText, _opensslSig), <List<int>>[]), throwsA(anything));
  });
}
