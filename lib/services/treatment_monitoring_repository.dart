import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/bta_examination.dart';
import '../models/treatment_monitoring.dart';
import '../models/treatment_plan.dart';
import '../models/user_profile.dart';

class TreatmentMonitoringRepository {
  TreatmentMonitoringRepository({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  Stream<TreatmentMonitoring?> treatmentForPatient(String patientId) =>
      _firestore
          .collection('treatments')
          .doc(patientId)
          .snapshots(includeMetadataChanges: true)
          .map(
            (document) => document.exists
                ? TreatmentMonitoring.fromDocument(document)
                : null,
          );

  Stream<List<BtaExamination>> examinationsForPatient(String patientId) =>
      _firestore
          .collection('btaExaminations')
          .where('patientId', isEqualTo: patientId)
          .snapshots(includeMetadataChanges: true)
          .map((snapshot) {
            final exams = snapshot.docs
                .map(BtaExamination.fromDocument)
                .toList(growable: true);
            exams.sort((a, b) {
              final aDate = a.examinationDate ?? a.scheduledDate;
              final bDate = b.examinationDate ?? b.scheduledDate;
              return aDate.compareTo(bDate);
            });
            return exams;
          });

  /// Creates only missing deterministic monitoring documents. Existing data
  /// and all medication records are left untouched.
  Future<void> ensureMonitoring(
    UserProfile profile, {
    bool repairPendingSchedule = false,
  }) async {
    final start = profile.treatmentStartedAt;
    if (profile.isDemo || profile.role != 'patient' || start == null) return;
    final treatmentRef = _firestore.collection('treatments').doc(profile.id);
    final schedules = _schedule(profile.id, start);
    // Querying by patientId is permitted by the existing Firestore read rule.
    // Reading deterministic documents that do not exist is not, which caused
    // the old transaction to fail before it could create the four schedules.
    final existingExaminations = await _firestore
        .collection('btaExaminations')
        .where('patientId', isEqualTo: profile.id)
        .get();
    final existingById = {
      for (final document in existingExaminations.docs) document.id: document,
    };

    await _firestore.runTransaction((transaction) async {
      final treatment = await transaction.get(treatmentRef);
      if (!treatment.exists) {
        transaction.set(treatmentRef, {
          'patientId': profile.id,
          'treatmentStartDate': Timestamp.fromDate(
            TreatmentPlan.dateOnly(start),
          ),
          'expectedCompletionDate': Timestamp.fromDate(
            TreatmentPlan.addMonths(TreatmentPlan.dateOnly(start), 6),
          ),
          'actualCompletionDate': null,
          'status': TreatmentStatus.ongoing.storageValue,
          'confirmedFailureType': ConfirmedFailureType.none.storageValue,
          'failureNotes': '',
          'conversionDetected': false,
          'possibleReversal': false,
          'confirmedReversal': false,
          'confirmedFailure': false,
          'treatmentOutcome': 'TREATMENT IN PROGRESS',
          'classificationReason':
              'Treatment completed? NO\nConfirmed treatment failure? NO\n'
              'Final classification: TREATMENT IN PROGRESS',
          'reasoningPath': const [
            'Treatment completed? NO',
            'Confirmed treatment failure? NO',
            'Final classification: TREATMENT IN PROGRESS',
          ],
          'lastClassificationUpdate': FieldValue.serverTimestamp(),
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
      for (final schedule in schedules) {
        final existing = existingById[schedule.reference.id];
        if (existing == null) {
          transaction.set(schedule.reference, {
            'patientId': profile.id,
            'examinationType': schedule.type.storageValue,
            'scheduledDate': Timestamp.fromDate(schedule.date),
            'examinationDate': null,
            'result': null,
            'notes': '',
            'enteredByCaregiver': null,
            'systemGenerated': true,
            'createdAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          });
          continue;
        }

        final data = existing.data();
        final updates = <String, Object?>{};
        if (data['examinationType'] == 'month2') {
          updates['examinationType'] = BtaExaminationType.month2.storageValue;
        }
        if (repairPendingSchedule &&
            data['systemGenerated'] == true &&
            data['result'] == null &&
            !_sameMonitoringDate(data['scheduledDate'], schedule.date)) {
          updates['scheduledDate'] = Timestamp.fromDate(schedule.date);
        }
        if (updates.isNotEmpty) {
          updates['updatedAt'] = FieldValue.serverTimestamp();
          transaction.update(existing.reference, updates);
        }
      }
    });
  }

  Future<void> saveExamination({
    required String caregiverId,
    required String patientId,
    required String examinationId,
    required BtaResult result,
    required String notes,
    required DateTime examinationDate,
  }) {
    if (result != BtaResult.positive && result != BtaResult.negative) {
      throw ArgumentError('Hasil monitoring harus positif atau negatif.');
    }
    return _firestore.collection('btaExaminations').doc(examinationId).update({
      // patientId, examinationType, and scheduledDate intentionally remain
      // untouched because they belong to the automatic monitoring schedule.
      'examinationDate': Timestamp.fromDate(
        TreatmentPlan.dateOnly(examinationDate),
      ),
      'result': result.storageValue,
      'notes': notes.trim(),
      'enteredByCaregiver': caregiverId,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> updateTreatmentStatus({
    required String caregiverId,
    required String patientId,
    required TreatmentStatus status,
    required ConfirmedFailureType confirmedFailureType,
    required String failureNotes,
    DateTime? actualCompletionDate,
  }) => _firestore.collection('treatments').doc(patientId).update({
    'status': status.storageValue,
    'actualCompletionDate': actualCompletionDate == null
        ? null
        : Timestamp.fromDate(TreatmentPlan.dateOnly(actualCompletionDate)),
    'confirmedFailureType': confirmedFailureType.storageValue,
    'failureNotes': failureNotes.trim(),
    'updatedByCaregiver': caregiverId,
    'updatedAt': FieldValue.serverTimestamp(),
  });

  List<_ScheduledDocument> _schedule(String patientId, DateTime value) {
    final dates = TreatmentPlan.btaMonitoringDates(value);
    return [
      _ScheduledDocument(
        reference: _firestore
            .collection('btaExaminations')
            .doc('bta_${patientId}_initial'),
        type: BtaExaminationType.initial,
        date: dates[0],
      ),
      _ScheduledDocument(
        reference: _firestore
            .collection('btaExaminations')
            .doc('bta_${patientId}_month2'),
        type: BtaExaminationType.month2,
        date: dates[1],
      ),
      _ScheduledDocument(
        reference: _firestore
            .collection('btaExaminations')
            .doc('bta_${patientId}_pre_final'),
        type: BtaExaminationType.preFinal,
        date: dates[2],
      ),
      _ScheduledDocument(
        reference: _firestore
            .collection('btaExaminations')
            .doc('bta_${patientId}_final'),
        type: BtaExaminationType.finalExam,
        date: dates[3],
      ),
    ];
  }
}

bool _sameMonitoringDate(Object? value, DateTime expected) =>
    value is Timestamp &&
    TreatmentPlan.dateOnly(value.toDate()) == TreatmentPlan.dateOnly(expected);

class _ScheduledDocument {
  const _ScheduledDocument({
    required this.reference,
    required this.type,
    required this.date,
  });

  final DocumentReference<Map<String, dynamic>> reference;
  final BtaExaminationType type;
  final DateTime date;
}
