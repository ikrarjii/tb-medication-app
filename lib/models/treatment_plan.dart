class TreatmentPlan {
  const TreatmentPlan._();

  static const group1 = 'group1';
  static const otherGroup = 'other';
  static const group1Label = 'Golongan 1';
  static const group1Weekdays = <int>{
    DateTime.monday,
    DateTime.wednesday,
    DateTime.friday,
  };

  static String labelFor(String group) => switch (group) {
    group1 => group1Label,
    otherGroup => 'Golongan Lain',
    _ => 'Golongan belum ditentukan',
  };

  static DateTime dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  static DateTime addMonths(DateTime value, int months) {
    final firstOfTargetMonth = DateTime(value.year, value.month + months, 1);
    final lastDay = DateTime(
      firstOfTargetMonth.year,
      firstOfTargetMonth.month + 1,
      0,
    ).day;
    return DateTime(
      firstOfTargetMonth.year,
      firstOfTargetMonth.month,
      value.day > lastDay ? lastDay : value.day,
    );
  }

  static DateTime endDate(String group, DateTime treatmentStartedAt) =>
      switch (group) {
        group1 => addMonths(dateOnly(treatmentStartedAt), 6),
        _ => dateOnly(treatmentStartedAt),
      };

  /// Start markers for the four existing BTA monitoring month windows.
  /// The exact examination day is intentionally not prescribed.
  static List<DateTime> btaMonitoringDates(DateTime treatmentStartedAt) {
    final start = dateOnly(treatmentStartedAt);
    return List<DateTime>.unmodifiable([
      start,
      addMonths(start, 2),
      addMonths(start, 4),
      addMonths(start, 5),
    ]);
  }

  static bool isScheduledDay({
    required String group,
    required DateTime treatmentStartedAt,
    required DateTime date,
  }) {
    final start = dateOnly(treatmentStartedAt);
    final day = dateOnly(date);
    if (day.isBefore(start) || !day.isBefore(endDate(group, start))) {
      return false;
    }
    if (group != group1) return false;

    final intensivePhaseEnd = addMonths(start, 2);
    return day.isBefore(intensivePhaseEnd) ||
        group1Weekdays.contains(day.weekday);
  }

  static List<DateTime> scheduledDays({
    required String group,
    required DateTime treatmentStartedAt,
  }) {
    final start = dateOnly(treatmentStartedAt);
    final end = endDate(group, start);
    final result = <DateTime>[];
    for (
      var day = start;
      day.isBefore(end);
      day = day.add(const Duration(days: 1))
    ) {
      if (isScheduledDay(group: group, treatmentStartedAt: start, date: day)) {
        result.add(day);
      }
    }
    return result;
  }

  static double progress({
    required String group,
    required DateTime treatmentStartedAt,
    required DateTime now,
  }) {
    final start = dateOnly(treatmentStartedAt);
    final end = endDate(group, start);
    final today = dateOnly(now);
    if (!today.isAfter(start)) return 0;
    if (!today.isBefore(end)) return 1;
    final totalDays = end.difference(start).inDays;
    return today.difference(start).inDays / totalDays;
  }

  static String dayKey(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}'
      '${day.month.toString().padLeft(2, '0')}'
      '${day.day.toString().padLeft(2, '0')}';
}
