const Duration medicationLateGracePeriod = Duration(minutes: 10);
const Duration medicationMissedAfter = Duration(hours: 18);

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
