import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/app_notification.dart';
import '../models/medication_timing.dart';
import '../models/medicine.dart';
import '../models/patient_pairing.dart';
import '../models/treatment_plan.dart';
import '../models/user_profile.dart';

class MedicineRepository {
  MedicineRepository({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  Stream<List<Medicine>> medicinesForPatient(String patientId) {
    return _firestore
        .collection('medicines')
        .where('patientId', isEqualTo: patientId)
        .snapshots(includeMetadataChanges: true)
        .map((snapshot) {
          final medicines = snapshot.docs
              .map(Medicine.fromDocument)
              .toList(growable: false);
          return medicines.toList()..sort(
            (a, b) => (b.scheduledAt ?? DateTime(1970)).compareTo(
              a.scheduledAt ?? DateTime(1970),
            ),
          );
        });
  }

  Stream<UserProfile> profile(String userId) {
    return _firestore
        .collection('users')
        .doc(userId)
        .snapshots(includeMetadataChanges: true)
        .map(UserProfile.fromDocument);
  }

  Future<Medicine?> medicineById(String medicineId) async {
    final document = await _firestore
        .collection('medicines')
        .doc(medicineId)
        .get();
    return document.exists ? Medicine.fromDocument(document) : null;
  }

  Future<void> markMedicineStatus(
    Medicine medicine, {
    required String status,
  }) async {
    if (status != 'taken' && status != 'missed') {
      throw ArgumentError.value(status, 'status', 'Status tidak didukung');
    }
    if (status == 'taken') {
      await _markAsTakenAtomically(medicine.id);
      return;
    }
    if (!medicine.isPending) return;
    final batch = _firestore.batch();
    final medicineRef = _firestore.collection('medicines').doc(medicine.id);
    batch.update(medicineRef, {
      'status': 'missed',
      'takenAt': FieldValue.delete(),
      'missedAt': FieldValue.serverTimestamp(),
      'respondedAt': FieldValue.serverTimestamp(),
      'responseAction': 'missed',
      'alarmState': 'stopped',
      'snoozedUntil': FieldValue.delete(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    batch.set(_firestore.collection('medicationLogs').doc(medicine.id), {
      'medicineId': medicine.id,
      'patientId': medicine.patientId,
      'name': medicine.name,
      'dosage': medicine.dosage,
      'scheduledAt': medicine.scheduledAt == null
          ? null
          : Timestamp.fromDate(medicine.scheduledAt!),
      'status': 'missed',
      'responseAction': 'missed',
      'takenAt': null,
      'missedAt': FieldValue.serverTimestamp(),
      'respondedAt': FieldValue.serverTimestamp(),
      'recordedAt': FieldValue.serverTimestamp(),
    });
    await batch.commit();
  }

  /// Reads the authoritative lifecycle state inside the transaction so a
  /// scheduler commit at the +18 hour boundary cannot erase a simultaneous
  /// patient response. A normal pending response creates its immutable log;
  /// an automatic miss recovers that existing log to `late` atomically.
  Future<void> _markAsTakenAtomically(String medicineId) async {
    final medicineRef = _firestore.collection('medicines').doc(medicineId);
    final logRef = _firestore.collection('medicationLogs').doc(medicineId);

    await _firestore.runTransaction((transaction) async {
      final snapshot = await transaction.get(medicineRef);
      if (!snapshot.exists) {
        throw StateError('Jadwal obat tidak lagi tersedia.');
      }
      final medicine = Medicine.fromDocument(snapshot);

      if (medicine.isTaken) return;

      if (medicine.isPending) {
        final respondedAt = DateTime.now();
        final scheduledAt = medicine.scheduledAt;
        final recordedStatus =
            scheduledAt != null &&
                isMedicationLate(
                  scheduledAt: scheduledAt,
                  respondedAt: respondedAt,
                )
            ? 'late'
            : 'taken';
        transaction.update(medicineRef, {
          'status': recordedStatus,
          'takenAt': FieldValue.serverTimestamp(),
          'missedAt': FieldValue.delete(),
          'respondedAt': FieldValue.serverTimestamp(),
          'responseAction': 'taken',
          'alarmState': 'stopped',
          'snoozedUntil': FieldValue.delete(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
        transaction.set(logRef, {
          'medicineId': medicine.id,
          'patientId': medicine.patientId,
          'name': medicine.name,
          'dosage': medicine.dosage,
          'scheduledAt': medicine.scheduledAt == null
              ? null
              : Timestamp.fromDate(medicine.scheduledAt!),
          'status': recordedStatus,
          'responseAction': 'taken',
          'takenAt': FieldValue.serverTimestamp(),
          'missedAt': null,
          'respondedAt': FieldValue.serverTimestamp(),
          'recordedAt': FieldValue.serverTimestamp(),
        });
        return;
      }

      if (!medicine.isAutomaticallyMissed) {
        throw StateError('Dosis ini sudah ditutup dan tidak dapat diubah.');
      }

      transaction.update(medicineRef, {
        'status': 'late',
        'takenAt': FieldValue.serverTimestamp(),
        'missedAt': FieldValue.delete(),
        'respondedAt': FieldValue.serverTimestamp(),
        'responseAction': 'taken',
        'alarmState': 'stopped',
        'updatedAt': FieldValue.serverTimestamp(),
      });
      transaction.update(logRef, {
        'status': 'late',
        'takenAt': FieldValue.serverTimestamp(),
        'missedAt': FieldValue.delete(),
        'respondedAt': FieldValue.serverTimestamp(),
        'responseAction': 'taken',
      });
    });
  }

  Future<void> markAsTaken(Medicine medicine) =>
      markMedicineStatus(medicine, status: 'taken');

  Future<void> markAsMissed(Medicine medicine) =>
      markMedicineStatus(medicine, status: 'missed');

  Future<void> recordReminderTriggered(Medicine medicine) async {
    if (!medicine.isPending || medicine.deviceTriggeredAt != null) return;
    final batch = _firestore.batch();
    batch.update(_firestore.collection('medicines').doc(medicine.id), {
      'deviceTriggeredAt': FieldValue.serverTimestamp(),
      'alarmState': 'ringing',
      'updatedAt': FieldValue.serverTimestamp(),
    });
    await batch.commit();
  }

  Future<void> snoozeMedicine(Medicine medicine, {required DateTime until}) {
    return _firestore.collection('medicines').doc(medicine.id).update({
      'snoozedUntil': Timestamp.fromDate(until),
      'lastSnoozedAt': FieldValue.serverTimestamp(),
      'snoozeCount': FieldValue.increment(1),
      'responseAction': 'snoozed',
      'alarmState': 'snoozed',
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> dismissMedicineAlarm(Medicine medicine) {
    return _firestore.collection('medicines').doc(medicine.id).update({
      'dismissedAt': FieldValue.serverTimestamp(),
      'responseAction': 'dismissed',
      'alarmState': 'dismissed',
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> updateNotificationSetting(String userId, bool enabled) {
    return _firestore.collection('users').doc(userId).update({
      'notificationsEnabled': enabled,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> updateProfile({
    required String userId,
    required String fullName,
    required String phoneNumber,
    int? age,
    String? gender,
  }) {
    final updates = <String, Object>{
      'fullName': fullName.trim(),
      'phoneNumber': phoneNumber.trim(),
      'updatedAt': FieldValue.serverTimestamp(),
    };
    if (age != null) {
      if (age < 0 || age > 120) {
        throw ArgumentError.value(age, 'age', 'Umur harus 0 sampai 120');
      }
      updates['age'] = age;
      updates['ageCategory'] = ageCategoryFor(age);
    }
    if (gender != null) {
      updates['gender'] = gender;
    }
    return _firestore.collection('users').doc(userId).update(updates);
  }

  /// Stores the only PMO-controlled treatment setting and materializes the
  /// immutable Group 1 treatment-day rules as deterministic medicine records.
  Future<void> configureMedicationTime({
    required String caregiverId,
    required String patientId,
    required int hour,
    required int minute,
  }) async {
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
      throw ArgumentError('Waktu minum obat tidak valid.');
    }

    final patientRef = _firestore.collection('users').doc(patientId);
    final patientSnapshot = await patientRef.get();
    final patientData = patientSnapshot.data();
    if (patientData == null || patientData['role'] != 'patient') {
      throw StateError('Profil pasien tidak ditemukan.');
    }
    final group =
        patientData['treatmentGroup'] as String? ?? TreatmentPlan.group1;
    if (group != TreatmentPlan.group1) {
      throw StateError('Aturan untuk kelompok terapi ini belum tersedia.');
    }
    final startedValue =
        patientData['treatmentStartedAt'] ?? patientData['createdAt'];
    if (startedValue is! Timestamp) {
      throw StateError(
        'Tanggal mulai terapi belum tersedia. Minta pasien login kembali.',
      );
    }
    final treatmentStartedAt = startedValue.toDate();
    final medicineSnapshot = await _firestore
        .collection('medicines')
        .where('patientId', isEqualTo: patientId)
        .get();
    final existingById = {
      for (final document in medicineSnapshot.docs) document.id: document,
    };

    var batch = _firestore.batch();
    var writes = 0;
    Future<void> flush() async {
      if (writes == 0) return;
      await batch.commit();
      batch = _firestore.batch();
      writes = 0;
    }

    for (final day in TreatmentPlan.scheduledDays(
      group: group,
      treatmentStartedAt: treatmentStartedAt,
    )) {
      final id = 'auto_${patientId}_${TreatmentPlan.dayKey(day)}';
      final scheduledAt = DateTime(day.year, day.month, day.day, hour, minute);
      final existing = existingById[id];
      if (existing == null) {
        batch.set(_firestore.collection('medicines').doc(id), {
          'caregiverId': caregiverId,
          'patientId': patientId,
          'name': 'MINUM OBAT',
          'dosage': 'Sesuai resep',
          'scheduledAt': Timestamp.fromDate(scheduledAt),
          'treatmentGroup': group,
          'treatmentDay': TreatmentPlan.dayKey(day),
          'systemGenerated': true,
          'status': 'pending',
          'scheduleRevision': 1,
          'alarmState': 'scheduled',
          'reminderTriggeredAt': null,
          'deviceTriggeredAt': null,
          'deviceTriggerPushedAt': null,
          'dueNotifiedAt': null,
          'lateNotifiedAt': null,
          'snoozedUntil': null,
          'dismissedAt': null,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
        writes++;
      } else if (existing.data()['status'] == 'pending') {
        batch.update(existing.reference, {
          'name': 'MINUM OBAT',
          'scheduledAt': Timestamp.fromDate(scheduledAt),
          'scheduleRevision': FieldValue.increment(1),
          'alarmState': 'scheduled',
          'reminderTriggeredAt': null,
          'deviceTriggeredAt': null,
          'deviceTriggerPushedAt': null,
          'dueNotifiedAt': null,
          'lateNotifiedAt': null,
          'snoozedUntil': null,
          'dismissedAt': null,
          'lastSnoozedAt': null,
          'snoozeCount': 0,
          'responseAction': null,
          'updatedAt': FieldValue.serverTimestamp(),
        });
        writes++;
      }
      if (writes >= 400) await flush();
    }

    // Pending schedules from the retired manual scheduler must not compete
    // with the generated treatment plan. Completed history is preserved.
    for (final document in medicineSnapshot.docs) {
      final data = document.data();
      if (data['status'] == 'pending' && data['systemGenerated'] != true) {
        batch.delete(document.reference);
        writes++;
        if (writes >= 400) await flush();
      }
    }

    batch.update(patientRef, {
      'medicationHour': hour,
      'medicationMinute': minute,
      'medicationTimeUpdatedBy': caregiverId,
      'medicationTimeUpdatedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    writes++;
    await flush();
  }

  Future<void> sendReminder({
    required String caregiverId,
    required String patientId,
  }) {
    final batch = _firestore.batch();
    final reminder = _firestore.collection('reminders').doc();
    batch.set(reminder, {
      'caregiverId': caregiverId,
      'patientId': patientId,
      'type': 'caregiver_reminder',
      'status': 'pending',
      'createdAt': FieldValue.serverTimestamp(),
    });
    batch.set(_firestore.collection('notifications').doc(reminder.id), {
      'recipientId': patientId,
      'patientId': patientId,
      'type': 'caregiver_reminder',
      'title': 'Pengingat dari pendamping',
      'message': 'Pendamping mengingatkan Anda untuk memeriksa jadwal obat.',
      'read': false,
      'createdAt': FieldValue.serverTimestamp(),
    });
    return batch.commit();
  }

  Stream<List<PatientPairing>> linkedPatients(String caregiverId) {
    return _firestore
        .collection('pairings')
        .where('caregiverId', isEqualTo: caregiverId)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map(PatientPairing.fromDocument)
              .where((pairing) => pairing.patientId.isNotEmpty)
              .toList(growable: false),
        );
  }

  Stream<List<PatientPairing>> linkedCaregivers(String patientId) {
    return _firestore
        .collection('pairings')
        .where('patientId', isEqualTo: patientId)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map(PatientPairing.fromDocument)
              .toList(growable: false),
        );
  }

  Future<void> linkPatientByCode({
    required String caregiverId,
    required String patientCode,
  }) async {
    final code = patientCode.trim().toUpperCase().replaceAll(' ', '');
    if (code.isEmpty) throw StateError('Masukkan kode pasien.');
    final codeSnapshot = await _firestore
        .collection('patientCodes')
        .doc(code)
        .get();
    final data = codeSnapshot.data();
    final patientId = data?['patientId'] as String?;
    final patientName = data?['patientName'] as String?;
    if (patientId == null || patientId.isEmpty) {
      throw StateError('Kode pasien tidak ditemukan.');
    }
    if (patientId == caregiverId) {
      throw StateError('Akun tidak dapat dihubungkan ke dirinya sendiri.');
    }
    await _firestore
        .collection('pairings')
        .doc('${caregiverId}_$patientId')
        .set({
          'caregiverId': caregiverId,
          'patientId': patientId,
          'patientName': patientName ?? 'Pasien',
          'invitationCode': code,
          'createdAt': FieldValue.serverTimestamp(),
        });
  }

  Future<void> unlinkPatient({
    required String caregiverId,
    required String patientId,
  }) {
    return _firestore
        .collection('pairings')
        .doc('${caregiverId}_$patientId')
        .delete();
  }

  Stream<List<AppNotification>> notificationsFor(String recipientId) {
    return _firestore
        .collection('notifications')
        .where('recipientId', isEqualTo: recipientId)
        .snapshots(includeMetadataChanges: true)
        .map((snapshot) {
          final notifications = snapshot.docs
              .map(AppNotification.fromDocument)
              .toList(growable: false);
          return notifications.toList()..sort(
            (a, b) => (b.createdAt ?? DateTime(1970)).compareTo(
              a.createdAt ?? DateTime(1970),
            ),
          );
        });
  }

  Future<void> markNotificationRead(String notificationId) {
    return _firestore.collection('notifications').doc(notificationId).update({
      'read': true,
      'readAt': FieldValue.serverTimestamp(),
    });
  }

  /// Marks every unread notification for [recipientId] as read.
  ///
  /// This intentionally avoids the composite (`recipientId`, `read`) query:
  /// Firestore does not auto-index multi-field queries, so that query would
  /// fail at runtime unless a composite index were deployed. Instead we use
  /// the single-field `recipientId` query (auto-indexed) and filter the
  /// unread subset client-side, keeping the inbox action working without a
  /// `firebase deploy`.
  Future<void> markAllNotificationsRead(String recipientId) async {
    final snapshot = await _firestore
        .collection('notifications')
        .where('recipientId', isEqualTo: recipientId)
        .get();
    final batch = _firestore.batch();
    var pending = 0;
    for (final document in snapshot.docs) {
      if (document.data()['read'] == true) continue;
      batch.update(document.reference, {
        'read': true,
        'readAt': FieldValue.serverTimestamp(),
      });
      pending++;
    }
    if (pending > 0) await batch.commit();
  }
}
