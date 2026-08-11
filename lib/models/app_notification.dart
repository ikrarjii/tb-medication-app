import 'package:cloud_firestore/cloud_firestore.dart';

class AppNotification {
  const AppNotification({
    required this.id,
    required this.recipientId,
    required this.title,
    required this.message,
    required this.type,
    required this.isRead,
    this.patientId,
    this.medicineId,
    this.createdAt,
  });

  final String id;
  final String recipientId;
  final String title;
  final String message;
  final String type;
  final bool isRead;
  final String? patientId;
  final String? medicineId;
  final DateTime? createdAt;

  factory AppNotification.fromDocument(
    QueryDocumentSnapshot<Map<String, dynamic>> document,
  ) {
    final data = document.data();
    final createdAt = data['createdAt'];
    return AppNotification(
      id: document.id,
      recipientId: data['recipientId'] as String? ?? '',
      title: data['title'] as String? ?? 'Pemberitahuan',
      message: data['message'] as String? ?? '',
      type: data['type'] as String? ?? 'info',
      isRead: data['read'] as bool? ?? false,
      patientId: data['patientId'] as String?,
      medicineId: data['medicineId'] as String?,
      createdAt: createdAt is Timestamp ? createdAt.toDate() : null,
    );
  }
}
