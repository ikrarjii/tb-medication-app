import 'package:flutter_application_1/models/medicine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rekap status hanya menghitung dosis yang sudah jatuh tempo', () {
    final now = DateTime(2026, 4, 10, 12);
    final medicines = [
      Medicine(
        id: 'on-time',
        name: 'Obat terapi',
        patientId: 'patient-1',
        status: 'taken',
        scheduledAt: DateTime(2026, 4, 8, 8),
        takenAt: DateTime(2026, 4, 8, 8, 5),
      ),
      Medicine(
        id: 'late',
        name: 'Obat terapi',
        patientId: 'patient-1',
        status: 'taken',
        scheduledAt: DateTime(2026, 4, 9, 8),
        takenAt: DateTime(2026, 4, 9, 8, 11),
      ),
      Medicine(
        id: 'missed',
        name: 'Obat terapi',
        patientId: 'patient-1',
        status: 'pending',
        scheduledAt: DateTime(2026, 4, 9, 8),
      ),
      Medicine(
        id: 'future',
        name: 'Obat terapi',
        patientId: 'patient-1',
        status: 'pending',
        scheduledAt: DateTime(2026, 4, 11, 8),
      ),
    ];

    final summary = MedicationStatusSummary.fromMedicines(
      medicines,
      now: now,
    );

    expect(summary.onTime, 1);
    expect(summary.late, 1);
    expect(summary.missed, 1);
  });

  test('rekap enam bulan memakai batas awal inklusif dan akhir eksklusif', () {
    final start = DateTime(2026, 1, 10);
    final end = DateTime(2026, 7, 10);
    final medicines = [
      for (final entry in <(String, DateTime)>[
        ('before', DateTime(2026, 1, 9, 8)),
        ('first-day', DateTime(2026, 1, 10, 8)),
        ('last-day', DateTime(2026, 7, 9, 8)),
        ('after', DateTime(2026, 7, 10, 8)),
      ])
        Medicine(
          id: entry.$1,
          name: 'Obat terapi',
          patientId: 'patient-1',
          status: 'taken',
          scheduledAt: entry.$2,
          takenAt: entry.$2,
        ),
    ];

    final summary = MedicationStatusSummary.fromMedicines(
      medicines,
      now: DateTime(2026, 8),
      startsAt: start,
      endsAt: end,
    );

    expect(summary.onTime, 2);
    expect(summary.late, 0);
    expect(summary.missed, 0);
  });
}
