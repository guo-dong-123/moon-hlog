///|
/// Returns P99 for the selected tag using MoonHlog's public API.
pub fn read_p99(text : StringView, tag : String) -> Int64? raise @hlog.HlogError {
  let selection : @hlog.Selection = {
    tag: Some(tag),
    from: None,
    until: None,
  }
  match @hlog.parse_log(text).aggregate(selection) {
    Some(histogram) => histogram.percentile(9900)
    None => None
  }
}

///|
/// Counts the tag/window pairs present on only one side.
pub fn missing_windows(
  baseline : StringView,
  candidate : StringView,
) -> Int raise @hlog.HlogError {
  let selection : @hlog.Selection = Default::default()
  let baseline_windows = @hlog.WindowAccumulator(selection, 1.0)
  let candidate_windows = @hlog.WindowAccumulator(selection, 1.0)
  let baseline_parser = @hlog.LogParser(selection=selection)
  let candidate_parser = @hlog.LogParser(selection=selection)
  for line in baseline.split("\n") {
    if baseline_parser.push(line) is Some(interval) {
      baseline_windows.add(interval)
    }
  }
  for line in candidate.split("\n") {
    if candidate_parser.push(line) is Some(interval) {
      candidate_windows.add(interval)
    }
  }
  let rows = baseline_windows.compare(candidate_windows)
  let mut missing = 0
  for row in rows {
    if row.baseline is None || row.candidate is None {
      missing += 1
    }
  }
  missing
}
