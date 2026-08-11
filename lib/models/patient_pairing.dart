import 'package:cloud_firestore/cloud_firestore.dart';

class PatientPairing {
  const PatientPairing({required this.patientId, required this.patientName});

  final String patientId;
  final String patientName;

  factory PatientPairing.fromDocument(
    QueryDocumentSnapshot<Map<String, dynamic>> document,
  ) {
    final data = document.data();
    final patientId = data['patientId'] as String? ?? '';
    return PatientPairing(
      patientId: patientId,
      patientName: data['patientName'] as String? ?? patientId,
    );
  }
}
