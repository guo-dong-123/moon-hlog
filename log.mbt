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
) -> (String?, Double, Double, String, Histogram) raise HlogError {
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
  (
    tag,
    timestamp,
    duration,
    peak_text.to_owned(),
    decode_histogram(fields[offset + 3].trim()),
  )
}

///|
/// Reads an HdrHistogram interval log with V2 compressed integer payloads.
pub fn parse_log(text : StringView) -> Log raise HlogError {
  let entries : Array[Interval] = []
  let mut start : Double? = None
  let mut base : Double? = None
  let mut line_number = 0
  for raw in text.split("\n") {
    line_number += 1
    let line = raw.trim()
    try {
      if line.length() == 0 ||
        line.has_prefix("\"StartTimestamp\"") ||
        line.has_prefix("StartTimestamp,") {
        ()
      } else if line.has_prefix("#[StartTime:") {
        if entries.length() != 0 {
          raise Invalid("StartTime must precede data")
        }
        start = Some(comment_time(line, "#[StartTime:"))
      } else if line.has_prefix("#[BaseTime:") {
        if entries.length() != 0 {
          raise Invalid("BaseTime must precede data")
        }
        base = Some(comment_time(line, "#[BaseTime:"))
      } else if !line.has_prefix("#") {
        let (tag, timestamp, duration, peak_text, histogram) = parse_row(line)
        let origin = start.unwrap_or(timestamp)
        if start is None {
          start = Some(origin)
        }
        let anchor = base.unwrap_or(
          if timestamp < origin - 31536000.0 {
            origin
          } else {
            0.0
          },
        )
        if base is None {
          base = Some(anchor)
        }
        let absolute_start = timestamp + anchor
        let relative_start = timestamp - (origin - anchor)
        if !finite(absolute_start + duration) || !finite(relative_start) {
          raise Invalid("interval time is out of range")
        }
        entries.push({
          tag,
          timestamp,
          peak_text,
          relative_start,
          absolute_start,
          duration,
          histogram,
        })
      }
    } catch {
      Invalid(reason) => raise Invalid("line \{line_number}: \{reason}")
      Unsupported(reason) => raise Unsupported("line \{line_number}: \{reason}")
      Incompatible(reason) => raise Incompatible(reason)
    }
  }
  { entries, start_time: start.unwrap_or(0.0), base_time: base.unwrap_or(0.0), }
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
