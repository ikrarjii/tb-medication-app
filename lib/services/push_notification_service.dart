import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../firebase_options.dart';
import 'reminder_service.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  }
  // Android schedule and due payloads are applied by the native FCM receiver
  // before this background isolate starts. That path can schedule/cancel
  // AlarmManager entries and launch the full-screen alarm while the app is
  // terminated; this callback remains registered so firebase_messaging keeps
  // delivering all other background messages normally.
}

class PushNotificationService {
  PushNotificationService._();

  static final PushNotificationService instance = PushNotificationService._();

  String? _activeUserId;
  StreamSubscription<String>? _tokenSubscription;
  StreamSubscription<RemoteMessage>? _messageSubscription;
  StreamSubscription<RemoteMessage>? _openedSubscription;

  void startForUser(String userId) {
    // Firebase in this project is currently configured for Android only.
    // Calling firebase_messaging on Windows/Linux produces a
    // MissingPluginException because those hosts do not register the plugin.
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    if (_activeUserId == userId) return;
    final previousUserId = _activeUserId;
    _activeUserId = userId;
    unawaited(_start(userId, previousUserId: previousUserId));
  }

  void reconfigureForUser(String userId) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    if (_activeUserId == userId) _activeUserId = null;
    startForUser(userId);
  }

  Future<void> _start(String userId, {String? previousUserId}) async {
    try {
      await _tokenSubscription?.cancel();
      await _messageSubscription?.cancel();
      await _openedSubscription?.cancel();
      final messaging = FirebaseMessaging.instance;
      if (previousUserId != null && previousUserId != userId) {
        await _removeCurrentToken(previousUserId);
      }
      if (_activeUserId != userId) return;
      final profile = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get();
      if (profile.data()?['notificationsEnabled'] == false) {
        await _removeCurrentToken(userId);
        return;
      }
      await messaging.requestPermission(alert: true, badge: true, sound: true);
      _tokenSubscription = messaging.onTokenRefresh.listen(
        (token) {
          if (_activeUserId == userId) unawaited(_saveToken(userId, token));
        },
        onError: (Object error) {
          debugPrint('Pembaruan token FCM gagal: $error');
        },
      );
      _messageSubscription = FirebaseMessaging.onMessage.listen((message) {
        unawaited(_handleMessage(userId, message, foreground: true));
      });
      _openedSubscription = FirebaseMessaging.onMessageOpenedApp.listen(
        (message) => unawaited(_handleMessage(userId, message)),
      );
      final initialMessage = await messaging.getInitialMessage();
      if (initialMessage != null && _activeUserId == userId) {
        await _handleMessage(userId, initialMessage);
      }
      final token = await messaging.getToken();
      if (token != null && _activeUserId == userId) {
        await _saveToken(userId, token);
      }
    } on MissingPluginException catch (error) {
      debugPrint(
        'Firebase Messaging belum terdaftar. Lakukan full restart aplikasi: $error',
      );
    } on FirebaseException catch (error) {
      // Token registration depends on a working, compatible Google Play
      // services installation. Keep local reminders and the rest of the app
      // usable when FCM is temporarily unavailable; onTokenRefresh above will
      // persist a token if registration later recovers while the app is alive.
      debugPrint(
        'Registrasi FCM gagal (${error.code}): ${error.message ?? error}',
      );
    } on PlatformException catch (error) {
      debugPrint('Firebase Messaging tidak tersedia: $error');
    }
  }

  Future<void> _handleMessage(
    String userId,
    RemoteMessage message, {
    bool foreground = false,
  }) async {
    if (_activeUserId != userId) return;
    final data = message.data;
    final type = data['type'];
    final patientId = data['patientId'] ?? '';
    if (type == 'due' && patientId == userId) {
      // The app's native receiver is authoritative for Android due events and
      // prevents a foreground Firebase callback from firing the alarm twice.
      return;
    }
    if (!foreground) return;
    final notification = message.notification;
    if (notification == null) return;
    await ReminderService.instance.showImmediate(
      id: message.messageId?.hashCode ?? DateTime.now().hashCode,
      title: notification.title ?? 'Kontrol Obat',
      body: notification.body ?? 'Ada pembaruan pengobatan.',
    );
  }

  Future<void> _saveToken(String userId, String token) {
    return FirebaseFirestore.instance.collection('users').doc(userId).update({
      'fcmTokens': FieldValue.arrayUnion([token]),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> _removeCurrentToken(String userId) async {
    final token = await FirebaseMessaging.instance.getToken();
    if (token == null) return;
    await FirebaseFirestore.instance.collection('users').doc(userId).update({
      'fcmTokens': FieldValue.arrayRemove([token]),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> stopAndUnregister() async {
    final userId = _activeUserId;
    _activeUserId = null;
    await _tokenSubscription?.cancel();
    await _messageSubscription?.cancel();
    await _openedSubscription?.cancel();
    if (userId != null &&
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android) {
      try {
        await _removeCurrentToken(userId);
      } on FirebaseException catch (error) {
        debugPrint('Token notifikasi belum dapat dihapus: $error');
      } on PlatformException catch (error) {
        debugPrint('Token notifikasi tidak tersedia: $error');
      }
    }
    _tokenSubscription = null;
    _messageSubscription = null;
    _openedSubscription = null;
  }

  void stop() => unawaited(stopAndUnregister());
}
