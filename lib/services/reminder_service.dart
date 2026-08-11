import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/medicine.dart';

class MedicationAlarmEvent {
  const MedicationAlarmEvent({
    required this.action,
    required this.notificationId,
    required this.medicineId,
    required this.patientId,
    required this.name,
    this.dosage,
    this.scheduledAt,
    this.occurredAt,
    this.snoozedUntil,
  });

  final String action;
  final int notificationId;
  final String medicineId;
  final String patientId;
  final String name;
  final String? dosage;
  final DateTime? scheduledAt;
  final DateTime? occurredAt;
  final DateTime? snoozedUntil;

  factory MedicationAlarmEvent.fromMap(Map<Object?, Object?> map) {
    final scheduledAt = map['scheduledAt'];
    final occurredAt = map['occurredAt'];
    final snoozedUntil = map['snoozedUntil'];
    return MedicationAlarmEvent(
      action: map['action'] as String? ?? 'fired',
      notificationId: (map['id'] as num?)?.toInt() ?? 0,
      medicineId: map['medicineId'] as String? ?? '',
      patientId: map['patientId'] as String? ?? '',
      name: map['name'] as String? ?? 'Obat',
      dosage: map['dosage'] as String?,
      scheduledAt: scheduledAt is num
          ? DateTime.fromMillisecondsSinceEpoch(scheduledAt.toInt())
          : null,
      occurredAt: occurredAt is num
          ? DateTime.fromMillisecondsSinceEpoch(occurredAt.toInt())
          : null,
      snoozedUntil: snoozedUntil is num
          ? DateTime.fromMillisecondsSinceEpoch(snoozedUntil.toInt())
          : null,
    );
  }
}

/// Coordinates Android alarm scheduling with the Flutter response UI.
/// Firestore remains the source of truth; native alarms are a device-local
/// projection that is reconciled whenever the live medicine stream changes.
class ReminderService {
  ReminderService._();

  static final ReminderService instance = ReminderService._();
  static const MethodChannel _channel = MethodChannel(
    'medicine_control/reminders',
  );

  final StreamController<MedicationAlarmEvent> _alarmEvents =
      StreamController<MedicationAlarmEvent>.broadcast();
  final List<MedicationAlarmEvent> _pendingEvents = [];
  bool _initialized = false;

  Stream<MedicationAlarmEvent> get alarmEvents => _alarmEvents.stream;

  bool get _supportsNativeAlarms =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> initialize() async {
    if (_initialized || !_supportsNativeAlarms) return;
    _initialized = true;
    _channel.setMethodCallHandler(_handleNativeCall);
    try {
      await _channel.invokeMethod<void>('initializeChannels');
      final pending = await _channel.invokeMethod<List<Object?>>(
        'getPendingAlarmEvents',
      );
      for (final item in pending ?? const <Object?>[]) {
        if (item is Map) {
          _pendingEvents.add(_eventFromMap(item.cast<Object?, Object?>()));
        }
      }
    } on PlatformException {
      // The app still works with its Firestore schedule if native alarms fail.
    } on MissingPluginException {
      // Useful for widget tests and non-Android development hosts.
    }
  }

  List<MedicationAlarmEvent> takePendingEvents() {
    final events = List<MedicationAlarmEvent>.of(_pendingEvents);
    _pendingEvents.clear();
    return events;
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method != 'alarmEvent') return;
    final arguments = call.arguments;
    if (arguments is! Map) return;
    final event = _eventFromMap(arguments.cast<Object?, Object?>());
    if (_alarmEvents.hasListener) {
      _alarmEvents.add(event);
    } else {
      _pendingEvents.add(event);
    }
  }

  MedicationAlarmEvent _eventFromMap(Map<Object?, Object?> map) =>
      MedicationAlarmEvent.fromMap(map);

  Future<bool> requestPermission() async {
    if (!_supportsNativeAlarms) return false;
    try {
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Starts Android's user-visible access flow for exact alarms, full-screen
  /// alarm notifications, and battery-optimization exemption. The native
  /// scheduler retains future payloads and arms them as exact alarms as soon
  /// as Android grants exact-alarm access.
  Future<bool> requestAlarmAccess() async {
    if (!_supportsNativeAlarms) return false;
    try {
      return await _channel.invokeMethod<bool>('requestAlarmAccess') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<Map<String, bool>> alarmAccessStatus() async {
    if (!_supportsNativeAlarms) return const <String, bool>{};
    try {
      final status = await _channel.invokeMapMethod<String, bool>(
        'getAlarmAccessStatus',
      );
      return status ?? const <String, bool>{};
    } on PlatformException {
      return const <String, bool>{};
    } on MissingPluginException {
      return const <String, bool>{};
    }
  }

  Future<void> setActivePatient(String? patientId) async {
    if (!_supportsNativeAlarms) return;
    try {
      await _channel.invokeMethod<void>('setActivePatient', {
        'patientId': patientId ?? '',
      });
    } on PlatformException {
      // Firestore and FCM token targeting remain the primary account guard.
    } on MissingPluginException {
      // Non-Android test hosts do not register the channel.
    }
  }

  Future<void> scheduleMedicines(List<Medicine> medicines) async {
    if (!_supportsNativeAlarms) return;
    final now = DateTime.now();
    final activeIds = <int>[];
    for (final medicine in medicines) {
      if (!medicine.isPending) continue;
      final reminderId = reminderIdForMedicine(medicine.id);
      // Keep an already-fired alarm active until Taken/Snooze/Dismiss handles
      // it. A later schedule snapshot must still cancel it on delete/complete.
      activeIds.add(reminderId);
      final snoozedUntil = medicine.snoozedUntil;
      final alarmAt = snoozedUntil != null && snoozedUntil.isAfter(now)
          ? snoozedUntil
          : medicine.scheduledAt;
      if (alarmAt == null || !alarmAt.isAfter(now)) continue;
      try {
        await _channel.invokeMethod<void>('schedule', {
          ..._payload(medicine, id: reminderId, scheduledAt: alarmAt),
        });
      } on PlatformException {
        // Server due notifications remain the fallback.
      } on MissingPluginException {
        return;
      }
    }
    try {
      await _channel.invokeMethod<void>('sync', {'activeIds': activeIds});
    } on PlatformException {
      // A later stream emission or app resume will reconcile again.
    } on MissingPluginException {
      // Non-Android test hosts do not register the channel.
    }
  }

  /// Cancels every device-local reminder and drops any response owned by the
  /// account being signed out. Normal empty schedule snapshots deliberately do
  /// not clear durable response events.
  Future<void> clearAllReminders() async {
    if (!_supportsNativeAlarms) return;
    try {
      await setActivePatient(null);
      await _channel.invokeMethod<void>('sync', {
        'activeIds': <int>[],
        'clearPendingEvent': true,
      });
      _pendingEvents.clear();
    } on PlatformException {
      // A later login reconciliation cancels stale scheduled alarms.
    } on MissingPluginException {
      // Non-Android test hosts do not register the channel.
    }
  }

  /// Repairs one local alarm without reconciling (and potentially cancelling)
  /// every other alarm owned by the signed-in patient.
  Future<void> scheduleMedicineWithoutSync(Medicine medicine) async {
    if (!_supportsNativeAlarms || !medicine.isPending) return;
    final now = DateTime.now();
    final snoozedUntil = medicine.snoozedUntil;
    final alarmAt = snoozedUntil != null && snoozedUntil.isAfter(now)
        ? snoozedUntil
        : medicine.scheduledAt;
    if (alarmAt == null || !alarmAt.isAfter(now)) return;
    try {
      await _channel.invokeMethod<void>('schedule', {
        ..._payload(
          medicine,
          id: reminderIdForMedicine(medicine.id),
          scheduledAt: alarmAt,
        ),
      });
    } on PlatformException {
      // The next Firestore snapshot performs a full reconciliation.
    } on MissingPluginException {
      // Non-Android test hosts do not register the channel.
    }
  }

  /// Removes a durable native response only after its matching Firestore
  /// mutation has completed. The native side compares all three fields so a
  /// newer response can never be acknowledged accidentally.
  Future<void> acknowledgeAlarmEvent(MedicationAlarmEvent event) async {
    if (!_supportsNativeAlarms) return;
    try {
      await _channel.invokeMethod<void>('ackAlarmEvent', {
        'id': event.notificationId,
        'action': event.action,
        'occurredAt': event.occurredAt?.millisecondsSinceEpoch ?? 0,
      });
    } on PlatformException {
      // Keeping the event is safe; it will be replayed and deduplicated later.
    } on MissingPluginException {
      // Non-Android test hosts do not register the channel.
    }
  }

  Future<void> triggerRemoteAlarm({
    required String medicineId,
    required String patientId,
    required String name,
    String? dosage,
    DateTime? scheduledAt,
  }) async {
    if (medicineId.isEmpty) return;
    final id = reminderIdForMedicine(medicineId);
    final event = MedicationAlarmEvent(
      action: 'fired',
      notificationId: id,
      medicineId: medicineId,
      patientId: patientId,
      name: name,
      dosage: dosage,
      scheduledAt: scheduledAt,
      occurredAt: DateTime.now(),
    );
    if (_alarmEvents.hasListener) {
      _alarmEvents.add(event);
    } else {
      _pendingEvents.add(event);
    }
    if (!_supportsNativeAlarms) return;
    try {
      await _channel.invokeMethod<void>('showAlarm', {
        'id': id,
        'medicineId': medicineId,
        'patientId': patientId,
        'name': name,
        'dosage': dosage ?? '',
        'title': 'Waktunya minum $name',
        'body': dosage?.isNotEmpty == true
            ? 'Minum $dosage sesuai jadwal.'
            : 'Jadwal minum obat Anda sudah tiba.',
        'scheduledAt':
            scheduledAt?.millisecondsSinceEpoch ??
            DateTime.now().millisecondsSinceEpoch,
      });
    } on PlatformException {
      // The in-app full-screen dialog remains available.
    }
  }

  Future<void> snooze(
    Medicine medicine, {
    Duration duration = const Duration(minutes: 5),
  }) async {
    if (!_supportsNativeAlarms) return;
    final alarmAt = DateTime.now().add(duration);
    try {
      await _channel.invokeMethod<void>('snooze', {
        ..._payload(
          medicine,
          id: reminderIdForMedicine(medicine.id),
          scheduledAt: alarmAt,
        ),
        'minutes': duration.inMinutes,
      });
    } on PlatformException {
      // Firestore keeps the snooze state visible even if OS scheduling fails.
    }
  }

  Future<void> stopAlarmForMedicine(String medicineId) async {
    if (!_supportsNativeAlarms || medicineId.isEmpty) return;
    try {
      await _channel.invokeMethod<void>('stop', {
        'id': reminderIdForMedicine(medicineId),
      });
    } on PlatformException {
      // The native alarm may already have stopped through its action button.
    }
  }

  Future<void> showImmediate({
    required int id,
    required String title,
    required String body,
  }) async {
    if (!_supportsNativeAlarms) return;
    try {
      await _channel.invokeMethod<void>('show', {
        'id': id & 0x7fffffff,
        'title': title,
        'body': body,
      });
    } on PlatformException {
      // The notification remains visible in the Firestore inbox.
    }
  }

  Map<String, Object> _payload(
    Medicine medicine, {
    required int id,
    required DateTime scheduledAt,
  }) => {
    'id': id,
    'medicineId': medicine.id,
    'patientId': medicine.patientId,
    'name': medicine.displayName,
    'dosage': medicine.dosage ?? '',
    'title': 'Waktunya ${medicine.displayName}',
    'body': medicine.dosage?.isNotEmpty == true
        ? 'Minum ${medicine.dosage} sesuai jadwal.'
        : 'Jadwal minum obat Anda sudah tiba.',
    'scheduleRevision': medicine.scheduleRevision,
    'scheduledAt': scheduledAt.millisecondsSinceEpoch,
  };
}

/// A deterministic identifier keeps PendingIntents stable across app restarts.
int reminderIdForMedicine(String medicineId) {
  var hash = 0x811c9dc5;
  for (final codeUnit in medicineId.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  final positive = hash & 0x7fffffff;
  return positive == 0 ? 1 : positive;
}
