import 'package:cloud_firestore/cloud_firestore.dart';

enum BtaExaminationType {
  initial('initial', 'Pemeriksaan 1 • Bulan ke-1'),
  // Keep the legacy storage value so existing Firestore records remain valid.
  month2('month_2', 'Pemeriksaan 2 • Bulan ke-3'),
  preFinal('pre_final', 'Pemeriksaan 3 • Bulan ke-5'),
  finalExam('final', 'Pemeriksaan 4 • Bulan ke-6'),
  confirmation('confirmation', 'Pemeriksaan ulang / konfirmasi');

  const BtaExaminationType(this.storageValue, this.label);

  final String storageValue;
  final String label;

  static BtaExaminationType fromStorage(Object? value) {
    // Older backend-generated month-3 records used the document key as the
    // stored type. Read that value correctly while it is migrated in place.
    if (value == 'month2') return BtaExaminationType.month2;
    return values.firstWhere(
      (item) => item.storageValue == value,
      orElse: () => BtaExaminationType.initial,
    );
  }
}

enum BtaResult {
  positive('positive', 'POSITIF'),
  negative('negative', 'NEGATIF'),
  tdl('tdl', 'TDL / TIDAK DAPAT DILAKUKAN'),
  notExamined('not_examined', 'BELUM DIPERIKSA');

  const BtaResult(this.storageValue, this.label);

  final String storageValue;
  final String label;

  bool get isBacteriologicallyValid =>
      this == BtaResult.positive || this == BtaResult.negative;

  static BtaResult? fromStorage(Object? value) {
    for (final item in values) {
      if (item.storageValue == value) return item;
    }
    return null;
  }
}

class BtaExamination {
  const BtaExamination({
    required this.id,
    required this.patientId,
    required this.type,
    required this.scheduledDate,
    this.examinationDate,
    this.result,
    this.notes = '',
    this.enteredByCaregiver,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String patientId;
  final BtaExaminationType type;
  final DateTime scheduledDate;
  final DateTime? examinationDate;
  final BtaResult? result;
  final String notes;
  final String? enteredByCaregiver;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get hasResult => result != null;
  bool get isConfirmation => type == BtaExaminationType.confirmation;

  factory BtaExamination.fromDocument(
    DocumentSnapshot<Map<String, dynamic>> document,
  ) {
    final data = document.data() ?? const <String, dynamic>{};
    return BtaExamination(
      id: document.id,
      patientId: data['patientId'] as String? ?? '',
      type: BtaExaminationType.fromStorage(data['examinationType']),
      scheduledDate:
          _date(data['scheduledDate']) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      examinationDate: _date(data['examinationDate']),
      result: BtaResult.fromStorage(data['result']),
      notes: data['notes'] as String? ?? '',
      enteredByCaregiver: data['enteredByCaregiver'] as String?,
      createdAt: _date(data['createdAt']),
      updatedAt: _date(data['updatedAt']),
    );
  }
}

DateTime? _date(Object? value) => value is Timestamp ? value.toDate() : null;
