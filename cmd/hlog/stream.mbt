///|
struct ReadStats {
  checked : Int64
  skipped : Int64
}

///|
fn selection(options : Options) -> @hloglib.Selection {
  { tag: options.tag, from: options.from, until: options.until, }
}

///|
struct AggregatedInput {
  histogram : @hloglib.Histogram?
  stats : ReadStats
}

///|
async fn scan(
  path : String,
  options : Options,
  consume : (@hloglib.Interval) -> Unit raise @hloglib.HlogError,
) -> ReadStats raise @hloglib.HlogError {
  let parser = @hloglib.LogParser(
    selection=selection(options),
    selected_only=options.selected_only,
  )
  try {
    let file = @asyncfs.open(path, mode=ReadOnly)
    defer file.close()
    let reader : &@asyncio.Reader = file
    while reader.read_until("\n") is Some(line) {
      if parser.push(line[:]) is Some(entry) {
        consume(entry)
      }
    }
  } catch {
    @hloglib.Invalid(reason) => raise @hloglib.Invalid("\{path}: \{reason}")
    @hloglib.Unsupported(reason) =>
      raise @hloglib.Unsupported("\{path}: \{reason}")
    @hloglib.Incompatible(reason) =>
      raise @hloglib.Incompatible("\{path}: \{reason}")
    _ => raise @hloglib.Invalid("cannot read \{path}")
  }
  { checked: parser.checked_payloads(), skipped: parser.skipped_payloads(), }
}

///|
async fn selected_histogram(
  path : String,
  options : Options,
) -> AggregatedInput raise @hloglib.HlogError {
  let mut histogram : @hloglib.Histogram? = None
  let stats = scan(path, options, entry => {
    histogram = match histogram {
      None => Some(entry.histogram)
      Some(existing) => Some(existing.merge(entry.histogram))
    }
  })
  { histogram, stats, }
}

///|
fn require_samples(
  path : String,
  input : AggregatedInput,
) -> @hloglib.Histogram raise @hloglib.HlogError {
  match input.histogram {
    Some(histogram) if histogram.count() > 0L => histogram
    _ => raise @hloglib.Invalid("\{path}: no samples match the selection")
  }
}

///|
async fn read_windows(
  path : String,
  options : Options,
  seconds : Double,
) -> (@hloglib.WindowAccumulator, ReadStats) raise @hloglib.HlogError {
  let accumulator = @hloglib.WindowAccumulator(selection(options), seconds)
  let stats = scan(path, options, entry => accumulator.add(entry))
  (accumulator, stats)
}

///|
fn stats_json(stats : ReadStats) -> String {
  "{\"checked_payloads\":\{stats.checked},\"skipped_payloads\":\{stats.skipped}}"
}

///|
fn explain_validation(path : String, stats : ReadStats) -> Unit {
  println(
    "\{path}: checked \{stats.checked} payloads, skipped \{stats.skipped} unselected payloads",
  )
}

///|
fn comparison_validation_json(before : ReadStats, after : ReadStats) -> String {
  "{\"mode\":\"selected_only\",\"baseline\":\{stats_json(before)},\"candidate\":\{stats_json(after)}}"
}
