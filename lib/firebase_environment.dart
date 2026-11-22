import 'package:flutter/foundation.dart';

/// Emulator routing requires an explicit dart-define and a debug build.
/// Non-debug builds fail fast if the emulator define is accidentally passed.
class FirebaseEnvironment {
  const FirebaseEnvironment._();

  static const _emulatorRequested = bool.fromEnvironment(
    'USE_FIREBASE_EMULATOR',
    defaultValue: false,
  );

  static const demoProjectId = 'demo-tb-monitoring';
  static const authPort = 9199;
  static const firestorePort = 8180;
  static const _emulatorHostOverride = String.fromEnvironment(
    'FIREBASE_EMULATOR_HOST',
    defaultValue: '',
  );

  static bool get useAutomaticHostMapping =>
      _emulatorHostOverride.isEmpty;

  static bool get useEmulator {
    if (_emulatorRequested && !kDebugMode) {
      throw StateError('Firebase Emulator mode can only run in a debug build.');
    }
    return _emulatorRequested;
  }

  static String get emulatorHost {
    if (_emulatorHostOverride.isNotEmpty) return _emulatorHostOverride;
    return defaultTargetPlatform == TargetPlatform.android
        ? '10.0.2.2'
        : '127.0.0.1';
  }
}