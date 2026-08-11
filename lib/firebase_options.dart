import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

class DefaultFirebaseOptions {
  const DefaultFirebaseOptions._();

  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError(
        'Firebase has not been configured for web. Run flutterfire configure '
        'and select the web platform.',
      );
    }

    return switch (defaultTargetPlatform) {
      TargetPlatform.android => android,
      _ => throw UnsupportedError(
        'Firebase has only been configured for Android in this project.',
      ),
    };
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyAIJViirgLQNuTRSf4Uj4ydcBYaSnJoIY4',
    appId: '1:712116554051:android:21efa03267e73727c5c7f6',
    messagingSenderId: '712116554051',
    projectId: 'drugcontrol-a35e2',
    storageBucket: 'drugcontrol-a35e2.firebasestorage.app',
  );
}
