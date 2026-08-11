import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_application_1/widgets/condition_barometer.dart';
import 'package:flutter_application_1/widgets/adherence_indicator.dart';
import 'package:flutter_application_1/models/bta_examination.dart';
import 'package:flutter_application_1/models/medication_timing.dart';
import 'package:flutter_application_1/models/medicine.dart';
import 'package:flutter_application_1/models/treatment_plan.dart';
import 'package:flutter_application_1/models/user_profile.dart';
import 'package:flutter_application_1/services/reminder_service.dart';
import 'package:flutter_application_1/screens/bta_examination_form_screen.dart';

void main() {
  test('application test harness is configured', () {
    expect(true, isTrue);
  });

  testWidgets('barometer kondisi menampilkan status tercatat', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ConditionBarometer(condition: 'moderate')),
      ),
    );

    expect(find.text('Kondisi tercatat'), findsOneWidget);
    expect(find.text('Sedang'), findsOneWidget);
    expect(find.textContaining('bukan merupakan diagnosis'), findsOneWidget);
  });

  testWidgets('form monitoring mengunci jadwal dan membatasi hasil BTA', (
    tester,
  ) async {
    final examination = BtaExamination(
      id: 'bta_patient-1_month2',
      patientId: 'patient-1',
      type: BtaExaminationType.month2,
      scheduledDate: DateTime(2026, 3, 10),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: BtaExaminationFormScreen(
          patientId: 'patient-1',
          examination: examination,
        ),
      ),
    );

    expect(find.text('Isi Hasil Monitoring BTA'), findsOneWidget);
    expect(find.text('Pemeriksaan 2 • Bulan ke-3'), findsOneWidget);
    expect(
      find.text('Dilakukan kapan saja dalam rentang bulan pemeriksaan ini'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
    expect(find.text('Tambah Pemeriksaan BTA'), findsNothing);
    expect(find.text('Tanggal pemeriksaan terjadwal'), findsNothing);

    await tester.tap(find.byType(DropdownButtonFormField<BtaResult>));
    await tester.pumpAndSettle();
    expect(find.text('POSITIF'), findsOneWidget);
    expect(find.text('NEGATIF'), findsOneWidget);
    expect(find.text('TDL / TIDAK DAPAT DILAKUKAN'), findsNothing);
    expect(find.text('BELUM DIPERIKSA'), findsNothing);
  });

  test('tingkat kepatuhan mengikuti ambang warna aplikasi', () {
    expect(
      adherenceLevelFromMedicines(confirmedDoses: 10, totalScheduledDoses: 10),
      AdherenceLevel.high,
    );
    expect(
      adherenceLevelFromMedicines(confirmedDoses: 9, totalScheduledDoses: 10),
      AdherenceLevel.medium,
    );
    expect(
      adherenceLevelFromMedicines(confirmedDoses: 7, totalScheduledDoses: 10),
      AdherenceLevel.low,
    );
  });

  test('tepat waktu sampai menit ke-10 dan terlambat setelahnya', () {
    final scheduledAt = DateTime(2026, 7, 22, 8);

    expect(
      isMedicationLate(
        scheduledAt: scheduledAt,
        respondedAt: scheduledAt.add(medicationLateGracePeriod),
      ),
      isFalse,
    );
    expect(
      isMedicationLate(
        scheduledAt: scheduledAt,
        respondedAt: scheduledAt.add(
          medicationLateGracePeriod + const Duration(milliseconds: 1),
        ),
      ),
      isTrue,
    );
  });

  test('batas terlewat otomatis adalah 18 jam dari jadwal', () {
    final scheduledAt = DateTime(2026, 7, 22, 8);

    expect(medicationMissedAfter, const Duration(hours: 18));
    expect(
      hasMedicationMissedDeadlinePassed(
        scheduledAt: scheduledAt,
        now: scheduledAt.add(
          medicationMissedAfter - const Duration(milliseconds: 1),
        ),
      ),
      isFalse,
    );
    expect(
      hasMedicationMissedDeadlinePassed(
        scheduledAt: scheduledAt,
        now: scheduledAt.add(medicationMissedAfter),
      ),
      isTrue,
    );
  });

  test('UI mengoreksi data taken yang sebenarnya terlambat', () {
    final scheduledAt = DateTime(2026, 7, 22, 8);
    final onTime = Medicine(
      id: 'on-time',
      name: 'Obat terapi',
      patientId: 'patient-1',
      status: 'taken',
      scheduledAt: scheduledAt,
      takenAt: scheduledAt.add(medicationLateGracePeriod),
    );
    final late = Medicine(
      id: 'late',
      name: 'Obat terapi',
      patientId: 'patient-1',
      status: 'taken',
      scheduledAt: scheduledAt,
      takenAt: scheduledAt.add(const Duration(minutes: 11)),
    );

    expect(onTime.isTakenOnTime, isTrue);
    expect(onTime.displayName, 'MINUM OBAT');
    expect(onTime.displayStatus, 'Tepat waktu');
    expect(late.isTakenOnTime, isFalse);
    expect(late.isLateConfirmation, isTrue);
    expect(late.displayStatus, 'Terlambat');
  });

  test('countdown tidak pernah bernilai negatif', () {
    final now = DateTime(2026, 7, 22, 8);
    expect(
      medicationCountdown(now.add(const Duration(minutes: 5)), now),
      const Duration(minutes: 5),
    );
    expect(
      medicationCountdown(now.subtract(const Duration(seconds: 1)), now),
      Duration.zero,
    );
  });

  test('id alarm stabil dan positif untuk dokumen Firestore', () {
    final first = reminderIdForMedicine('medicine-document-123');
    expect(first, reminderIdForMedicine('medicine-document-123'));
    expect(first, greaterThan(0));
    expect(first, lessThanOrEqualTo(0x7fffffff));
    expect(first, isNot(reminderIdForMedicine('medicine-document-124')));
  });

  test('payload alarm native mempertahankan aksi dan waktu snooze', () {
    final event = MedicationAlarmEvent.fromMap({
      'action': 'snoozed',
      'id': 42,
      'medicineId': 'medicine-42',
      'patientId': 'patient-1',
      'name': 'Amoxicillin',
      'dosage': '1 tablet',
      'scheduledAt': 1000,
      'occurredAt': 2000,
      'snoozedUntil': 302000,
    });

    expect(event.action, 'snoozed');
    expect(event.medicineId, 'medicine-42');
    expect(event.occurredAt?.millisecondsSinceEpoch, 2000);
    expect(event.snoozedUntil?.millisecondsSinceEpoch, 302000);
  });

  test('automatic missed dapat dipulihkan hanya dalam 24 jam', () {
    final scheduledAt = DateTime(2026, 7, 22, 8);
    final medicine = Medicine(
      id: 'medicine-recovery',
      name: 'Amoxicillin',
      patientId: 'patient-1',
      status: 'missed',
      scheduledAt: scheduledAt,
      responseAction: 'automatic_missed',
    );

    expect(medicine.isAutomaticallyMissed, isTrue);
    expect(
      medicine.canRecoverAutomaticMissedAt(
        scheduledAt.add(const Duration(hours: 24)),
      ),
      isTrue,
    );
    expect(
      medicine.canRecoverAutomaticMissedAt(
        scheduledAt.add(const Duration(hours: 24, milliseconds: 1)),
      ),
      isFalse,
    );
  });

  test('manual missed tidak dapat diubah melalui jalur pemulihan', () {
    final scheduledAt = DateTime(2026, 7, 22, 8);
    final medicine = Medicine(
      id: 'medicine-manual-missed',
      name: 'Amoxicillin',
      patientId: 'patient-1',
      status: 'missed',
      scheduledAt: scheduledAt,
      responseAction: 'missed',
    );

    expect(medicine.isAutomaticallyMissed, isFalse);
    expect(
      medicine.canRecoverAutomaticMissedAt(
        scheduledAt.add(const Duration(hours: 2)),
      ),
      isFalse,
    );
  });

  test('kelompok 1 dijadwalkan setiap hari selama dua bulan pertama', () {
    final start = DateTime(2026, 1, 10);

    expect(
      TreatmentPlan.isScheduledDay(
        group: TreatmentPlan.group1,
        treatmentStartedAt: start,
        date: DateTime(2026, 3, 9),
      ),
      isTrue,
    );
    expect(
      TreatmentPlan.isScheduledDay(
        group: TreatmentPlan.group1,
        treatmentStartedAt: start,
        date: DateTime(2026, 3, 10),
      ),
      DateTime(2026, 3, 10).weekday == DateTime.monday ||
          DateTime(2026, 3, 10).weekday == DateTime.wednesday ||
          DateTime(2026, 3, 10).weekday == DateTime.friday,
    );
  });

  test('fase lanjutan kelompok 1 hanya Senin, Rabu, dan Jumat', () {
    final start = DateTime(2026, 1, 1);

    expect(
      TreatmentPlan.isScheduledDay(
        group: TreatmentPlan.group1,
        treatmentStartedAt: start,
        date: DateTime(2026, 3, 2),
      ),
      isTrue,
    );
    expect(
      TreatmentPlan.isScheduledDay(
        group: TreatmentPlan.group1,
        treatmentStartedAt: start,
        date: DateTime(2026, 3, 3),
      ),
      isFalse,
    );
    expect(
      TreatmentPlan.isScheduledDay(
        group: TreatmentPlan.group1,
        treatmentStartedAt: start,
        date: DateTime(2026, 3, 4),
      ),
      isTrue,
    );
  });

  test('jadwal kelompok 1 berhenti tepat setelah enam bulan', () {
    final start = DateTime(2026, 1, 31);
    expect(
      TreatmentPlan.endDate(TreatmentPlan.group1, start),
      DateTime(2026, 7, 31),
    );
    expect(
      TreatmentPlan.isScheduledDay(
        group: TreatmentPlan.group1,
        treatmentStartedAt: start,
        date: DateTime(2026, 7, 31),
      ),
      isFalse,
    );
  });

  test('kategori umur ditentukan otomatis pada batas 18 tahun', () {
    expect(ageCategoryFor(0), 'Anak');
    expect(ageCategoryFor(17), 'Anak');
    expect(ageCategoryFor(18), 'Dewasa');
    expect(ageCategoryFor(120), 'Dewasa');
  });

  test('label golongan lain tersedia tanpa aturan jadwal', () {
    expect(TreatmentPlan.labelFor(TreatmentPlan.otherGroup), 'Golongan Lain');
    expect(
      TreatmentPlan.scheduledDays(
        group: TreatmentPlan.otherGroup,
        treatmentStartedAt: DateTime(2026, 1, 1),
      ),
      isEmpty,
    );
  });
}
