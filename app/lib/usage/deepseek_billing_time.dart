/// DeepSeek's peak hours: Monday to Friday, 01:00-04:00 and 06:00-10:00 UTC.
/// China's public holidays are off-peak all day; they are not known here, so
/// a reply on one is priced as on a workday (a little high).
bool tavernDeepSeekPeak(DateTime at) {
  final utc = at.toUtc();
  if (utc.weekday == DateTime.saturday || utc.weekday == DateTime.sunday) return false;
  final hour = utc.hour;
  return (hour >= 1 && hour < 4) || (hour >= 6 && hour < 10);
}
