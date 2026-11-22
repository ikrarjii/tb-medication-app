const Duration medicationLateGracePeriod = Duration(minutes: 10);
const Duration medicationMissedAfter = Duration(hours: 18);

/// Displays a medication time consistently in the Indonesian 24-hour format.
///
/// The persisted schedule remains a Firestore [Timestamp], while the patient
/// profile keeps its hour and minute as integers. Formatting from those values
/// prevents a device's 12-hour setting from changing what users see.
String formatMedicationTime(int hour, int minute) {
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
    throw ArgumentError.value(
      '$hour:$minute',
      'waktu',
      'Jam minum obat tidak valid.',
    );
  }
  return '${hour.toString().padLeft(2, '0')}.${minute.toString().padLeft(2, '0')}';
}

bool isMedicationLate({
  required DateTime scheduledAt,
  required DateTime respondedAt,
}) => respondedAt.isAfter(scheduledAt.add(medicationLateGracePeriod));

bool hasMedicationMissedDeadlinePassed({
  required DateTime scheduledAt,
  required DateTime now,
}) => !now.isBefore(scheduledAt.add(medicationMissedAfter));

Duration medicationCountdown(DateTime scheduledAt, DateTime now) {
  final remaining = scheduledAt.difference(now);
  return remaining.isNegative ? Duration.zero : remaining;
}
