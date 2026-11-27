///|
/// A recorded interval. Times are in seconds and the histogram uses the producer's units.
pub struct Interval {
  tag : String?
  relative_start : Double
  absolute_start : Double
  duration : Double
  histogram : Histogram
  priv timestamp : Double
  priv peak_text : String
}

///|
/// A sequence of recorded intervals with a shared time origin.
pub struct Log {
  priv entries : Array[Interval]
  start_time : Double
  base_time : Double
}

///|
/// Limits a query to recorded interval starts in [from, until).
pub(all) struct Selection {
  tag : String?
  from : Double?
  until : Double?
} derive(Default)

///|
/// Returns a shallow copy of the immutable interval records in this log.
pub fn Log::intervals(self : Log) -> Array[Interval] {
  self.entries.copy()
}

///|
fn finite(value : Double) -> Bool {
  !(value.is_nan() || value.is_inf())
}

///|
fn number(text : StringView, field : String) -> Double raise HlogError {
  let value = @string.parse_double(text.trim()) catch {
    _ => raise Invalid("invalid \{field}")
  }
  if !finite(value) {
    raise Invalid("non-finite \{field}")
  }
  value
}

///|
// Java writes timestamps with three decimal places. Keep that grid exact
// through epoch subtraction, while retaining the precision of other inputs.
fn exact_milliseconds(seconds : Double) -> Int64? {
  let rounded = (seconds * 1000.0).round()
  if rounded.abs() <= 9007199254740991.0 && rounded / 1000.0 == seconds {
    Some(rounded.to_int64())
  } else {
    None
  }
}

///|
fn relative_seconds(
  timestamp : Double,
  origin : Double,
  anchor : Double,
) -> Double {
  match
    (
      exact_milliseconds(timestamp),
      exact_milliseconds(origin),
      exact_milliseconds(anchor),
    ) {
    (Some(t), Some(o), Some(a)) => (t - (o - a)).to_double() / 1000.0
    _ => timestamp - (origin - anchor)
  }
}

///|
fn comment_time(line : StringView, prefix : String) -> Double raise HlogError {
  let value = line[prefix.length():].trim()
  for field in value.split(" ") {
    let first = field.trim()
    if first.length() > 0 {
      return number(first, prefix)
    }
  }
  raise Invalid("missing timestamp after \{prefix}")
}

///|
fn parse_row(
  line : StringView,
) -> (String?, Double, Double, String, StringView) raise HlogError {
  let fields = line.split(",").collect()
  let tagged = fields.length() > 0 && fields[0].has_prefix("Tag=")
  let offset = if tagged { 1 } else { 0 }
  if fields.length() != offset + 4 {
    raise Invalid("expected timestamp, duration, peak, and histogram payload")
  }
  let tag = if tagged {
    let value = fields[0][4:].to_owned()
    if value.contains(" ") || value.contains("\r") {
      raise Invalid("histogram tag contains a delimiter")
    }
    Some(value)
  } else {
    None
  }
  let timestamp = number(fields[offset], "interval timestamp")
  let duration = number(fields[offset + 1], "interval duration")
  let peak_text = fields[offset + 2].trim()
  let peak = number(peak_text, "interval peak")
  if duration < 0.0 || peak < 0.0 {
    raise Invalid("negative duration or peak")
  }
  (tag, timestamp, duration, peak_text.to_owned(), fields[offset + 3].trim())
}

///|
/// Incremental parser for interval logs. The parser owns the time origin and line counter.
pub struct LogParser {
  priv selection : Selection
  priv selected_only : Bool
  priv mut start : Double?
  priv mut base : Double?
  priv mut saw_interval : Bool
  priv mut line_number : Int
  priv mut checked : Int64
  priv mut skipped : Int64
}

///|
/// Creates an incremental parser. Rows outside the selection are validated
/// unless selected_only explicitly permits skipping their compressed payloads.
pub fn LogParser::LogParser(
  selection? : Selection = Default::default(),
  selected_only? : Bool = false,
) -> LogParser raise HlogError {
  validate_selection(selection)
  {
    selection,
    selected_only,
    start: None,
    base: None,
    saw_interval: false,
    line_number: 0,
    checked: 0L,
    skipped: 0L,
  }
}

///|
/// Number of successfully decoded compressed payloads.
pub fn LogParser::checked_payloads(self : LogParser) -> Int64 {
  self.checked
}

///|
/// Number of compressed payloads skipped by an explicitly selective read.
pub fn LogParser::skipped_payloads(self : LogParser) -> Int64 {
  self.skipped
}

///|
/// Processes one complete input line, yielding a selected interval if present.
pub fn LogParser::push(
  self : LogParser,
  raw : StringView,
) -> Interval? raise HlogError {
  self.line_number += 1
  let line = raw.trim()
  try {
    if line.length() == 0 ||
      line.has_prefix("\"StartTimestamp\"") ||
      line.has_prefix("StartTimestamp,") {
      return None
    }
    if line.has_prefix("#[StartTime:") {
      if self.saw_interval {
        raise Invalid("StartTime must precede data")
      }
      self.start = Some(comment_time(line, "#[StartTime:"))
      return None
    }
    if line.has_prefix("#[BaseTime:") {
      if self.saw_interval {
        raise Invalid("BaseTime must precede data")
      }
      self.base = Some(comment_time(line, "#[BaseTime:"))
      return None
    }
    if line.has_prefix("#") {
      return None
    }
    let (tag, timestamp, duration, peak_text, payload) = parse_row(line)
    self.saw_interval = true
    let origin = self.start.unwrap_or(timestamp)
    if self.start is None {
      self.start = Some(origin)
    }
    let anchor = self.base.unwrap_or(
      if timestamp < origin - 31536000.0 {
        origin
      } else {
        0.0
      },
    )
    if self.base is None {
      self.base = Some(anchor)
    }
    let absolute_start = timestamp + anchor
    let relative_start = relative_seconds(timestamp, origin, anchor)
    if !finite(absolute_start + duration) || !finite(relative_start) {
      raise Invalid("interval time is out of range")
    }
    let selected = matches_coordinates(tag, relative_start, self.selection)
    if !selected && self.selected_only {
      self.skipped += 1L
      return None
    }
    let histogram = decode_histogram(payload)
    self.checked += 1L
    if selected {
      Some({
        tag,
        timestamp,
        peak_text,
        relative_start,
        absolute_start,
        duration,
        histogram,
      })
    } else {
      None
    }
  } catch {
    Invalid(reason) => raise Invalid("line \{self.line_number}: \{reason}")
    Unsupported(reason) =>
      raise Unsupported("line \{self.line_number}: \{reason}")
    Incompatible(reason) => raise Incompatible(reason)
  }
}

///|
/// Reads an HdrHistogram interval log with V2 compressed integer payloads.
pub fn parse_log(text : StringView) -> Log raise HlogError {
  let parser = LogParser()
  let entries : Array[Interval] = []
  for raw in text.split("\n") {
    if parser.push(raw) is Some(entry) {
      entries.push(entry)
    }
  }
  {
    entries,
    start_time: parser.start.unwrap_or(0.0),
    base_time: parser.base.unwrap_or(0.0),
  }
}

///|
/// Writes intervals in HdrHistogram log format, preserving the producer’s peak field.
pub fn Log::encode(self : Log) -> String raise HlogError {
  let output = StringBuilder()
  output.write_string("#[Histogram log format version 1.3]\n")
  output.write_string(
    "#[StartTime: \{self.start_time} (seconds since epoch)]\n",
  )
  output.write_string("#[BaseTime: \{self.base_time} (seconds since epoch)]\n")
  output.write_string(
    "\"StartTimestamp\",\"Interval_Length\",\"Interval_Max\",\"Interval_Compressed_Histogram\"\n",
  )
  for entry in self.entries {
    if entry.tag is Some(tag) {
      output.write_string("Tag=\{tag},")
    }
    let payload = entry.histogram.encode()
    output.write_string(
      "\{entry.timestamp},\{entry.duration},\{entry.peak_text},\{payload}\n",
    )
  }
  output.to_string()
}

///|
/// Selects interval starts relative to the log's start and merges their sample counts.
pub fn Log::aggregate(
  self : Log,
  selection : Selection,
) -> Histogram? raise HlogError {
  validate_selection(selection)
  let mut aggregate : Histogram? = None
  for entry in self.entries {
    if !matches_selection(entry, selection) {
      continue
    }
    aggregate = match aggregate {
      None => Some(entry.histogram)
      Some(histogram) => Some(histogram.merge(entry.histogram))
    }
  }
  aggregate
}
