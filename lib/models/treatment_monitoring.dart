import 'package:cloud_firestore/cloud_firestore.dart';

enum TreatmentStatus {
  ongoing('ongoing', 'DALAM PENGOBATAN'),
  completed('completed', 'SELESAI');

  const TreatmentStatus(this.storageValue, this.label);

  final String storageValue;
  final String label;

  static TreatmentStatus fromStorage(Object? value) => switch (value) {
    'completed' => TreatmentStatus.completed,
    _ => TreatmentStatus.ongoing,
  };
}

enum ConfirmedFailureType {
  none('none', 'Tidak ada kegagalan terkonfirmasi'),
  persistentBacteriologicalFailure(
    'persistent_bacteriological_failure',
    'Kegagalan bakteriologis persisten',
  ),
  regimenPermanentlyChanged(
    'regimen_permanently_changed',
    'Paduan obat diubah permanen karena respons tidak memadai',
  ),
  treatmentPermanentlyDiscontinued(
    'treatment_permanently_discontinued',
    'Pengobatan dihentikan permanen karena efek samping',
  ),
  additionalDrugResistance(
    'additional_drug_resistance',
    'Resistansi obat tambahan yang memerlukan perubahan paduan',
  );

  const ConfirmedFailureType(this.storageValue, this.label);

  final String storageValue;
  final String label;

  static ConfirmedFailureType fromStorage(Object? value) => values.firstWhere(
    (item) => item.storageValue == value,
    orElse: () => ConfirmedFailureType.none,
  );
}

class TreatmentMonitoring {
  const TreatmentMonitoring({
    required this.patientId,
    required this.treatmentStartDate,
    required this.expectedCompletionDate,
    this.actualCompletionDate,
    this.status = TreatmentStatus.ongoing,
    this.confirmedFailureType = ConfirmedFailureType.none,
    this.failureNotes = '',
    this.storedOutcome,
    this.storedReasoningPath = const [],
    this.lastClassificationUpdate,
  });

  final String patientId;
  final DateTime treatmentStartDate;
  final DateTime expectedCompletionDate;
  final DateTime? actualCompletionDate;
  final TreatmentStatus status;
  final ConfirmedFailureType confirmedFailureType;
  final String failureNotes;
  final String? storedOutcome;
  final List<String> storedReasoningPath;
  final DateTime? lastClassificationUpdate;

  bool get treatmentCompleted => status == TreatmentStatus.completed;
  bool get hasConfirmedFailure =>
      confirmedFailureType != ConfirmedFailureType.none;

  factory TreatmentMonitoring.fromDocument(
    DocumentSnapshot<Map<String, dynamic>> document,
  ) {
    final data = document.data() ?? const <String, dynamic>{};
    final start = _date(data['treatmentStartDate']) ?? DateTime.now();
    return TreatmentMonitoring(
      patientId: data['patientId'] as String? ?? document.id,
      treatmentStartDate: start,
      expectedCompletionDate:
          _date(data['expectedCompletionDate']) ??
          DateTime(start.year, start.month + 6, start.day),
      actualCompletionDate: _date(data['actualCompletionDate']),
      status: TreatmentStatus.fromStorage(data['status']),
      confirmedFailureType: ConfirmedFailureType.fromStorage(
        data['confirmedFailureType'],
      ),
      failureNotes: data['failureNotes'] as String? ?? '',
      storedOutcome: data['treatmentOutcome'] as String?,
      storedReasoningPath: (data['reasoningPath'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(growable: false),
      lastClassificationUpdate: _date(data['lastClassificationUpdate']),
    );
  }
}

DateTime? _date(Object? value) => value is Timestamp ? value.toDate() : null;
