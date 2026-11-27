///|
/// A histogram for a single tag and relative-time window.
pub struct WindowHistogram {
  tag : String?
  index : Int64
  histogram : Histogram
}

///|
fn matches_coordinates(
  entry_tag : String?,
  relative_start : Double,
  selection : Selection,
) -> Bool {
  if selection.tag is Some(tag) && entry_tag != Some(tag) {
    return false
  }
  if selection.from is Some(from) && relative_start < from {
    return false
  }
  if selection.until is Some(until) && relative_start >= until {
    return false
  }
  true
}

///|
fn matches_selection(entry : Interval, selection : Selection) -> Bool {
  matches_coordinates(entry.tag, entry.relative_start, selection)
}

///|
fn validate_selection(selection : Selection) -> Unit raise HlogError {
  if selection.from is Some(x) && !finite(x) {
    raise Invalid("window start must be finite")
  }
  if selection.until is Some(x) && !finite(x) {
    raise Invalid("window end must be finite")
  }
  if selection.from is Some(from) &&
    selection.until is Some(until) &&
    from >= until {
    raise Invalid("window start must precede end")
  }
}

///|
fn compare_window(a : WindowHistogram, b : WindowHistogram) -> Int {
  let tag_order = Option::compare(a.tag, b.tag)
  if tag_order != 0 {
    tag_order
  } else {
    a.index.compare(b.index)
  }
}

///|
fn window_index(start : Double, size : Double, size_ms : Int64?) -> Double {
  if exact_milliseconds(start) is Some(ms) && size_ms is Some(step) && step > 0L {
    let quotient = ms / step
    let index = if ms % step < 0L { quotient - 1L } else { quotient }
    index.to_double()
  } else {
    (start / size).floor()
  }
}

///|
/// Accumulates one merged histogram per tag and relative-time window.
pub struct WindowAccumulator {
  priv selection : Selection
  priv seconds : Double
  priv size_ms : Int64?
  priv groups : Map[(String?, Int64), Histogram]
}

///|
/// Creates a window accumulator with validated bounds.
pub fn WindowAccumulator::WindowAccumulator(
  selection : Selection,
  seconds : Double,
) -> WindowAccumulator raise HlogError {
  validate_selection(selection)
  if !finite(seconds) || seconds <= 0.0 {
    raise Invalid("window size must be finite and positive")
  }
  { selection, seconds, size_ms: exact_milliseconds(seconds), groups: {}, }
}

///|
/// Merges a selected interval into its corresponding window.
pub fn WindowAccumulator::add(
  self : WindowAccumulator,
  entry : Interval,
) -> Unit raise HlogError {
  if !matches_selection(entry, self.selection) {
    return
  }
  let index = window_index(entry.relative_start, self.seconds, self.size_ms)
  if !finite(index) ||
    index < -9007199254740991.0 ||
    index >= 9007199254740991.0 ||
    !finite(index * self.seconds) ||
    !finite((index + 1.0) * self.seconds) {
    raise Invalid("window index or boundary is out of range")
  }
  let key = (entry.tag, index.to_int64())
  let merged = match self.groups.get(key) {
    Some(existing) => existing.merge(entry.histogram)
    None => entry.histogram
  }
  self.groups[key] = merged
}

///|
/// Returns the merged histograms in tag and window order.
pub fn WindowAccumulator::windows(
  self : WindowAccumulator,
) -> Array[WindowHistogram] {
  let rows : Array[WindowHistogram] = []
  for item in self.groups {
    let ((tag, index), histogram) = item
    rows.push({ tag, index, histogram, })
  }
  rows.sort_by(compare_window)
  rows
}

///|
/// Groups selected interval starts into [index * seconds, (index + 1) * seconds).
/// Groups are sorted by tag and window index. Each selected interval contributes
/// all its samples to exactly one window.
pub fn Log::windows(
  self : Log,
  selection : Selection,
  seconds : Double,
) -> Array[WindowHistogram] raise HlogError {
  let accumulator = WindowAccumulator(selection, seconds)
  for entry in self.entries {
    accumulator.add(entry)
  }
  accumulator.windows()
}

///|
/// A paired window. Missing tags or windows remain explicit.
pub struct WindowComparison {
  tag : String?
  index : Int64
  baseline : Histogram?
  candidate : Histogram?
}

///|
/// Joins the union of selected tag/window keys from two logs.
pub fn Log::compare_windows(
  self : Log,
  other : Log,
  selection : Selection,
  seconds : Double,
) -> Array[WindowComparison] raise HlogError {
  join_windows(
    self.windows(selection, seconds),
    other.windows(selection, seconds),
  )
}

///|
/// Compares the sorted results of two accumulators with the same window size.
pub fn WindowAccumulator::compare(
  self : WindowAccumulator,
  other : WindowAccumulator,
) -> Array[WindowComparison] raise HlogError {
  if self.seconds != other.seconds ||
    self.selection.tag != other.selection.tag ||
    self.selection.from != other.selection.from ||
    self.selection.until != other.selection.until {
    raise Incompatible("window accumulators have different selections or sizes")
  }
  join_windows(self.windows(), other.windows())
}

///|
fn join_windows(
  baseline : Array[WindowHistogram],
  candidate : Array[WindowHistogram],
) -> Array[WindowComparison] {
  let result : Array[WindowComparison] = []
  let mut left = 0
  let mut right = 0
  while left < baseline.length() && right < candidate.length() {
    let a = baseline[left]
    let b = candidate[right]
    let order = compare_window(a, b)
    if order == 0 {
      result.push({
        tag: a.tag,
        index: a.index,
        baseline: Some(a.histogram),
        candidate: Some(b.histogram),
      })
      left += 1
      right += 1
    } else if order < 0 {
      result.push({
        tag: a.tag,
        index: a.index,
        baseline: Some(a.histogram),
        candidate: None,
      })
      left += 1
    } else {
      result.push({
        tag: b.tag,
        index: b.index,
        baseline: None,
        candidate: Some(b.histogram),
      })
      right += 1
    }
  }
  for i in left..<baseline.length() {
    let a = baseline[i]
    result.push({
      tag: a.tag,
      index: a.index,
      baseline: Some(a.histogram),
      candidate: None,
    })
  }
  for i in right..<candidate.length() {
    let b = candidate[i]
    result.push({
      tag: b.tag,
      index: b.index,
      baseline: None,
      candidate: Some(b.histogram),
    })
  }
  result
}
