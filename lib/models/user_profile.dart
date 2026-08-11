import 'package:cloud_firestore/cloud_firestore.dart';

class UserProfile {
  const UserProfile({
    required this.id,
    required this.fullName,
    required this.email,
    required this.phoneNumber,
    required this.role,
    this.photoUrl,
    this.patientCode,
    this.condition = 'mild',
    this.caregiverName,
    this.caregiverPhone,
    this.relationship,
    this.notificationsEnabled = true,
    this.birthDate,
    this.age,
    this.ageCategory,
    this.gender,
    this.treatmentGroup = 'group1',
    this.treatmentStartedAt,
    this.medicationHour,
    this.medicationMinute,
  });

  final String id;
  final String fullName;
  final String email;
  final String phoneNumber;
  final String role;
  final String? photoUrl;
  final String? patientCode;
  final String condition;
  final String? caregiverName;
  final String? caregiverPhone;
  final String? relationship;
  final bool notificationsEnabled;
  final DateTime? birthDate;
  final int? age;
  final String? ageCategory;
  final String? gender;
  final String treatmentGroup;
  final DateTime? treatmentStartedAt;
  final int? medicationHour;
  final int? medicationMinute;

  bool get hasMedicationTime =>
      medicationHour != null && medicationMinute != null;

  int? ageAt(DateTime date) {
    if (age != null) return age;
    final birth = birthDate;
    if (birth == null) return null;
    var calculatedAge = date.year - birth.year;
    if (date.month < birth.month ||
        (date.month == birth.month && date.day < birth.day)) {
      calculatedAge--;
    }
    return calculatedAge < 0 ? null : calculatedAge;
  }

  String ageCategoryAt(DateTime date) {
    if (ageCategory != null && ageCategory!.isNotEmpty) return ageCategory!;
    final currentAge = ageAt(date);
    return currentAge == null ? 'Belum diisi' : ageCategoryFor(currentAge);
  }

  String get genderLabel => switch (gender) {
    'male' => 'Laki-laki',
    'female' => 'Perempuan',
    _ => 'Belum diisi',
  };

  factory UserProfile.fromDocument(
    DocumentSnapshot<Map<String, dynamic>> document,
  ) {
    final data = document.data() ?? const <String, dynamic>{};
    return UserProfile(
      id: document.id,
      fullName: data['fullName'] as String? ?? 'Pengguna Kontrol Obat',
      email: data['email'] as String? ?? '',
      phoneNumber: data['phoneNumber'] as String? ?? '',
      role: data['role'] as String? ?? '',
      photoUrl: data['photoUrl'] as String?,
      patientCode: data['patientCode'] as String?,
      condition: data['condition'] as String? ?? 'mild',
      caregiverName: data['caregiverName'] as String?,
      caregiverPhone: data['caregiverPhone'] as String?,
      relationship: data['relationship'] as String?,
      notificationsEnabled: data['notificationsEnabled'] as bool? ?? true,
      birthDate: _date(data['birthDate']),
      age: (data['age'] as num?)?.toInt(),
      ageCategory: data['ageCategory'] as String?,
      gender: data['gender'] as String?,
      treatmentGroup: data['treatmentGroup'] as String? ?? 'group1',
      treatmentStartedAt: _date(
        data['treatmentStartedAt'] ?? data['createdAt'],
      ),
      medicationHour: (data['medicationHour'] as num?)?.toInt(),
      medicationMinute: (data['medicationMinute'] as num?)?.toInt(),
    );
  }
}

String ageCategoryFor(int age) => age < 18 ? 'Anak' : 'Dewasa';

DateTime? _date(Object? value) => value is Timestamp ? value.toDate() : null;
