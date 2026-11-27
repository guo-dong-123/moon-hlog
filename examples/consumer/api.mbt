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
  let rows = @hlog.parse_log(baseline).compare_windows(
    @hlog.parse_log(candidate), Default::default(), 1.0,
  )
  let mut missing = 0
  for row in rows {
    if row.baseline is None || row.candidate is None {
      missing += 1
    }
  }
  missing
}
