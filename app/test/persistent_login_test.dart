import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jph_real_estate_hr/core/app_lock.dart';
import 'package:jph_real_estate_hr/core/app_lock_gate.dart';
import 'package:jph_real_estate_hr/core/token_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The phone's lock, simulated: what the person would do at the system prompt.
class FakeDevice implements DeviceAuthenticator {
  bool hasLock;
  bool answer;
  int prompts = 0;
  FakeDevice({this.hasLock = true, this.answer = true});
  @override
  Future<bool> available() async => hasLock;
  @override
  Future<bool> confirm(String reason) async {
    prompts++;
    return answer;
  }
}

void main() {
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('the saved session (Android Keystore-backed storage)', () {
    test('app restart / device reboot: the token is read back from the secure storage, never from the plain settings', () async {
      await TokenStore.write('tok-123');
      final p = await SharedPreferences.getInstance();
      expect(p.getString('token'), isNull, reason: 'no plain-text copy');
      // a new run of the app (the storages persist across restarts and reboots; only the process is new)
      expect(await TokenStore.read(), 'tok-123');
      expect(await const FlutterSecureStorage().read(key: 'session_token'), 'tok-123');
    });

    test('an older plain session is moved into the secure storage on first read (not signed out)', () async {
      SharedPreferences.setMockInitialValues({'token': 'legacy-tok'});
      expect(await TokenStore.read(), 'legacy-tok');
      expect((await SharedPreferences.getInstance()).getString('token'), isNull, reason: 'the plain copy is removed after the move');
      expect(await TokenStore.read(), 'legacy-tok');
    });

    test('explicit sign-out clears the stored session', () async {
      await TokenStore.write('tok-123');
      await TokenStore.clear();
      expect(await TokenStore.read(), isNull);
      expect(await const FlutterSecureStorage().read(key: 'session_token'), isNull);
    });
  });

  group('app lock (fingerprint / face, or the device PIN / pattern / password)', () {
    test('off by default: a saved session opens directly (no prompt)', () async {
      final d = FakeDevice();
      final lock = AppLock(authenticator: d);
      await lock.init(hasSession: () => true);
      expect(lock.locked, isFalse);
      expect(d.prompts, 0);
    });

    test('turning it on asks the device first; refused → stays off', () async {
      final d = FakeDevice(answer: false);
      final lock = AppLock(authenticator: d);
      await lock.init(hasSession: () => true);
      expect(await lock.setEnabled(true), isFalse);
      expect(lock.enabled, isFalse);
      d.answer = true;
      expect(await lock.setEnabled(true), isTrue);
      expect(lock.enabled, isTrue);
      expect((await SharedPreferences.getInstance()).getBool(AppLock.prefKey), isTrue);
    });

    test('a device with no fingerprint and no screen lock cannot turn it on', () async {
      final lock = AppLock(authenticator: FakeDevice(hasLock: false));
      await lock.init(hasSession: () => true);
      expect(await lock.setEnabled(true), isFalse);
      expect(lock.enabled, isFalse);
    });

    test('restart / reboot with it on: starts locked; unlock (biometric or device PIN) opens; cancel keeps it locked', () async {
      SharedPreferences.setMockInitialValues({AppLock.prefKey: true});
      final d = FakeDevice(answer: false);
      final lock = AppLock(authenticator: d);
      await lock.init(hasSession: () => true);
      expect(lock.locked, isTrue);
      expect(await lock.unlock(), isFalse, reason: 'cancelled the prompt');
      expect(lock.locked, isTrue);
      d.answer = true; // fingerprint, face — or the device PIN / pattern / password offered by the same prompt
      expect(await lock.unlock(), isTrue);
      expect(lock.locked, isFalse);
    });

    test('no saved session (signed out): nothing to lock', () async {
      SharedPreferences.setMockInitialValues({AppLock.prefKey: true});
      final lock = AppLock(authenticator: FakeDevice());
      await lock.init(hasSession: () => false);
      expect(lock.locked, isFalse);
    });

    test('back from the background: locks again only after the relock time', () async {
      SharedPreferences.setMockInitialValues({AppLock.prefKey: true});
      var now = DateTime(2026, 11, 25, 10);
      final lock = AppLock(authenticator: FakeDevice(), relockAfter: const Duration(minutes: 5), clock: () => now);
      await lock.init(hasSession: () => true);
      await lock.unlock();
      lock.didChangeAppLifecycleState(AppLifecycleState.paused);
      now = now.add(const Duration(minutes: 2));
      lock.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(lock.locked, isFalse, reason: 'a short switch to another app');
      lock.didChangeAppLifecycleState(AppLifecycleState.paused);
      now = now.add(const Duration(minutes: 6));
      lock.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(lock.locked, isTrue);
    });

    test('turning it off also asks the device; a session that ends resets the lock', () async {
      SharedPreferences.setMockInitialValues({AppLock.prefKey: true});
      final d = FakeDevice();
      final lock = AppLock(authenticator: d);
      var signedIn = true;
      await lock.init(hasSession: () => signedIn);
      signedIn = false; // signed out / revoked
      lock.reset();
      expect(lock.locked, isFalse);
      final before = d.prompts;
      expect(await lock.setEnabled(false), isTrue);
      expect(d.prompts, before + 1);
      expect((await SharedPreferences.getInstance()).getBool(AppLock.prefKey), isFalse);
    });
  });

  group('the lock screen', () {
    testWidgets('covers the app while locked, prompts by itself, opens on success', (t) async {
      SharedPreferences.setMockInitialValues({AppLock.prefKey: true});
      final d = FakeDevice(answer: false);
      final lock = AppLock(authenticator: d);
      await lock.init(hasSession: () => true);
      await t.pumpWidget(MaterialApp(home: AppLockGate(lock: lock, onSignOut: () async {}, child: const Text('home'))));
      await t.pump();
      expect(find.byKey(const ValueKey('app-lock-screen')), findsOneWidget);
      expect(find.text('home'), findsNothing, reason: 'nothing of the app is visible');
      expect(d.prompts, 1, reason: 'the system prompt opens by itself');
      d.answer = true;
      await t.tap(find.byKey(const ValueKey('app-lock-unlock')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('app-lock-screen')), findsNothing);
      expect(find.text('home'), findsOneWidget);
    });

    testWidgets('«تسجيل الدخول من جديد» signs out', (t) async {
      SharedPreferences.setMockInitialValues({AppLock.prefKey: true});
      final lock = AppLock(authenticator: FakeDevice(answer: false));
      var signedIn = true;
      await lock.init(hasSession: () => signedIn);
      var signedOut = false;
      await t.pumpWidget(MaterialApp(home: AppLockGate(lock: lock, onSignOut: () async { signedOut = true; signedIn = false; },
          child: const Text('home'))));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('app-lock-sign-out')));
      await t.pumpAndSettle();
      expect(signedOut, isTrue);
      expect(find.byKey(const ValueKey('app-lock-screen')), findsNothing);
    });
  });
}
