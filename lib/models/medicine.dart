import 'package:cloud_firestore/cloud_firestore.dart';

import 'medication_timing.dart';

const automaticMissedRecoveryWindow = Duration(hours: 24);

class Medicine {
  const Medicine({
    required this.id,
    required this.name,
    required this.patientId,
    required this.status,
    this.caregiverId,
    this.dosage,
    this.scheduledAt,
    this.takenAt,
    this.respondedAt,
    this.reminderTriggeredAt,
    this.deviceTriggeredAt,
    this.snoozedUntil,
    this.dismissedAt,
    this.missedAt,
    this.alarmState,
    this.responseAction,
    this.scheduleRevision = 1,
  });

  final String id;
  final String name;
  final String patientId;
  final String status;
  final String? caregiverId;
  final String? dosage;
  final DateTime? scheduledAt;
  final DateTime? takenAt;
  final DateTime? respondedAt;
  final DateTime? reminderTriggeredAt;
  final DateTime? deviceTriggeredAt;
  final DateTime? snoozedUntil;
  final DateTime? dismissedAt;
  final DateTime? missedAt;
  final String? alarmState;
  final String? responseAction;
  final int scheduleRevision;

  bool get isTaken => status == 'taken' || status == 'late';
  bool get isLateConfirmation {
    if (status == 'late') return true;
    final scheduled = scheduledAt;
    final confirmed = respondedAt ?? takenAt;
    return status == 'taken' &&
        scheduled != null &&
        confirmed != null &&
        isMedicationLate(scheduledAt: scheduled, respondedAt: confirmed);
  }

  bool get isTakenOnTime => status == 'taken' && !isLateConfirmation;
  bool get isPending => status == 'pending';
  bool get isCompleted => isTaken || status == 'missed';
  bool get isAutomaticallyMissed =>
      status == 'missed' && responseAction == 'automatic_missed';

  bool canRecoverAutomaticMissedAt(DateTime now) {
    final scheduled = scheduledAt;
    return isAutomaticallyMissed &&
        scheduled != null &&
        !now.isAfter(scheduled.add(automaticMissedRecoveryWindow));
  }

  String get displayName {
    final value = name.trim();
    if (value.isEmpty) return 'OBAT TANPA NAMA';
    if (value.toLowerCase() == 'obat terapi') return 'MINUM OBAT';
    return value.toUpperCase();
  }

  String get displayStatus {
    if (isLateConfirmation) return 'Terlambat';
    if (status == 'taken') return 'Tepat waktu';
    if (status == 'missed') return 'Terlewat';
    return 'Belum diminum';
  }

  factory Medicine.fromDocument(
    DocumentSnapshot<Map<String, dynamic>> document,
  ) {
    final data = document.data() ?? const <String, dynamic>{};

    return Medicine(
      id: document.id,
      name: data['name'] as String? ?? 'Obat tanpa nama',
      patientId: data['patientId'] as String? ?? '',
      status: data['status'] as String? ?? 'unknown',
      caregiverId: data['caregiverId'] as String?,
      dosage: data['dosage'] as String?,
      scheduledAt: _date(data['scheduledAt']),
      takenAt: _date(data['takenAt']),
      respondedAt: _date(data['respondedAt']),
      reminderTriggeredAt: _date(data['reminderTriggeredAt']),
      deviceTriggeredAt: _date(data['deviceTriggeredAt']),
      snoozedUntil: _date(data['snoozedUntil']),
      dismissedAt: _date(data['dismissedAt']),
      missedAt: _date(data['missedAt']),
      alarmState: data['alarmState'] as String?,
      responseAction: data['responseAction'] as String?,
      scheduleRevision: (data['scheduleRevision'] as num?)?.toInt() ?? 1,
    );
  }
}

class MedicationStatusSummary {
  const MedicationStatusSummary({
    this.onTime = 0,
    this.late = 0,
    this.missed = 0,
  });

  final int onTime;
  final int late;
  final int missed;

  factory MedicationStatusSummary.fromMedicines(
    Iterable<Medicine> medicines, {
    required DateTime now,
    DateTime? startsAt,
    DateTime? endsAt,
  }) {
    var onTime = 0;
    var late = 0;
    var missed = 0;

    for (final medicine in medicines) {
      final scheduledAt = medicine.scheduledAt;
      if (scheduledAt == null || scheduledAt.isAfter(now)) continue;
      if (startsAt != null && scheduledAt.isBefore(startsAt)) continue;
      if (endsAt != null && !scheduledAt.isBefore(endsAt)) continue;

      if (medicine.isTakenOnTime) {
        onTime++;
      } else if (medicine.isLateConfirmation) {
        late++;
      } else if (medicine.status == 'missed' ||
          (medicine.isPending &&
              hasMedicationMissedDeadlinePassed(
                scheduledAt: scheduledAt,
                now: now,
              ))) {
        missed++;
      } else if (medicine.isPending &&
          isMedicationLate(scheduledAt: scheduledAt, respondedAt: now)) {
        late++;
      }
    }

    return MedicationStatusSummary(
      onTime: onTime,
      late: late,
      missed: missed,
    );
  }
}

DateTime? _date(Object? value) => value is Timestamp ? value.toDate() : null;
