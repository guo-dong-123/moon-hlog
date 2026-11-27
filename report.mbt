///|
/// A histogram for a single tag and relative-time window.
pub struct WindowHistogram {
  tag : String?
  index : Int64
  histogram : Histogram
}

///|
fn matches_selection(entry : Interval, selection : Selection) -> Bool {
  if selection.tag is Some(tag) && entry.tag != Some(tag) {
    return false
  }
  if selection.from is Some(from) && entry.relative_start < from {
    return false
  }
  if selection.until is Some(until) && entry.relative_start >= until {
    return false
  }
  true
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
/// Groups selected interval starts into [index * seconds, (index + 1) * seconds).
/// Groups are sorted by tag and window index. Each selected interval contributes
/// all its samples to exactly one window.
pub fn Log::windows(
  self : Log,
  selection : Selection,
  seconds : Double,
) -> Array[WindowHistogram] raise HlogError {
  validate_selection(selection)
  if !finite(seconds) || seconds <= 0.0 {
    raise Invalid("window size must be finite and positive")
  }
  let size_ms = exact_milliseconds(seconds)
  let entries : Array[WindowHistogram] = []
  for entry in self.entries {
    if !matches_selection(entry, selection) {
      continue
    }
    let index = window_index(entry.relative_start, seconds, size_ms)
    if !finite(index) ||
      index < -9007199254740991.0 ||
      index >= 9007199254740991.0 ||
      !finite(index * seconds) ||
      !finite((index + 1.0) * seconds) {
      raise Invalid("window index or boundary is out of range")
    }
    entries.push({
      tag: entry.tag,
      index: index.to_int64(),
      histogram: entry.histogram,
    })
  }
  entries.sort_by(compare_window)
  let result : Array[WindowHistogram] = []
  for entry in entries {
    let last = result.length() - 1
    if last >= 0 && compare_window(result[last], entry) == 0 {
      let histogram = result[last].histogram.merge(entry.histogram)
      result[last] = { tag: entry.tag, index: entry.index, histogram, }
    } else {
      result.push(entry)
    }
  }
  result
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
  let baseline = self.windows(selection, seconds)
  let candidate = other.windows(selection, seconds)
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
