///|
let usage : String =
  #|MoonHlog
  #|  hlog summary LOG [--tag TAG] [--from SECONDS] [--until SECONDS] [--json]
  #|  hlog compare BASELINE CANDIDATE [--tag TAG] [--from SECONDS] [--until SECONDS]
  #|               [--max-p99-increase-pct PCT] [--json]
  #|  hlog rewrite INPUT OUTPUT
  #|
  #|Window bounds use interval start time relative to each log's StartTime.
  #|Histogram values use the producer's native units.

///|
struct Options {
  mut tag : String?
  mut from : Double?
  mut until : Double?
  mut max_increase : Double?
  mut json : Bool
}

///|
fn read_number(
  name : String,
  value : String,
) -> Double raise @hloglib.HlogError {
  let n = @string.parse_double(value[:]) catch {
    _ => raise @hloglib.Invalid("invalid value for \{name}: \{value}")
  }
  if n.is_nan() || n.is_inf() {
    raise @hloglib.Invalid("expected finite number for \{name}")
  }
  n
}

///|
fn read_options(
  args : ArrayView[String],
  compare : Bool,
) -> Options raise @hloglib.HlogError {
  let options : Options = {
    tag: None,
    from: None,
    until: None,
    max_increase: None,
    json: false,
  }
  for i = 0; i < args.length(); {
    let flag = args[i]
    if flag == "--json" {
      options.json = true
      continue i + 1
    }
    if i + 1 >= args.length() {
      raise @hloglib.Invalid("missing value or unrecognized option: \{flag}")
    }
    let value = args[i + 1]
    match flag {
      "--tag" => options.tag = Some(value)
      "--from" => options.from = Some(read_number(flag, value))
      "--until" => options.until = Some(read_number(flag, value))
      "--max-p99-increase-pct" if compare => {
        let percent = read_number(flag, value)
        if percent < 0.0 {
          raise @hloglib.Invalid("max P99 increase must be nonnegative")
        }
        options.max_increase = Some(percent)
      }
      _ =>
        raise @hloglib.Invalid("unrecognized option or invalid value: \{flag}")
    }
    continue i + 2
  }
  options
}

///|
fn load(path : String) -> @hloglib.Log raise @hloglib.HlogError {
  let text = @fs.read_file_to_string(path) catch {
    _ => raise @hloglib.Invalid("cannot read \{path}")
  }
  @hloglib.parse_log(text[:]) catch {
    @hloglib.Invalid(reason) => raise @hloglib.Invalid("\{path}: \{reason}")
    @hloglib.Unsupported(reason) =>
      raise @hloglib.Unsupported("\{path}: \{reason}")
    error => raise error
  }
}

///|
fn selected(
  path : String,
  options : Options,
) -> @hloglib.Histogram raise @hloglib.HlogError {
  let selection : @hloglib.Selection = {
    tag: options.tag,
    from: options.from,
    until: options.until,
  }
  match load(path).aggregate(selection) {
    Some(histogram) if histogram.count() > 0L => histogram
    _ => raise @hloglib.Invalid("\{path}: no samples match the selection")
  }
}

///|
fn summary(histogram : @hloglib.Histogram, json : Bool) -> String {
  let samples = histogram.count()
  let p50 = histogram.percentile(5000).unwrap_or(0L)
  let p95 = histogram.percentile(9500).unwrap_or(0L)
  let p99 = histogram.percentile(9900).unwrap_or(0L)
  let p999 = histogram.percentile(9990).unwrap_or(0L)
  if json {
    "{\"samples\":\{samples},\"p50\":\{p50},\"p95\":\{p95},\"p99\":\{p99},\"p999\":\{p999}}"
  } else {
    "samples=\{samples}  P50=\{p50}  P95=\{p95}  P99=\{p99}  P99.9=\{p999}"
  }
}

///|
fn compare(
  baseline : String,
  candidate : String,
  options : Options,
) -> Int raise @hloglib.HlogError {
  let before = selected(baseline, options)
  let after = selected(candidate, options)
  let prior = before.percentile(9900).unwrap_or(0L)
  let current = after.percentile(9900).unwrap_or(0L)
  let change = if prior == 0L {
    None
  } else {
    Some((current - prior).to_double() * 100.0 / prior.to_double())
  }
  let exceeded = match options.max_increase {
    None => false
    Some(limit) =>
      match change {
        None => current > 0L
        Some(value) => value > limit
      }
  }
  if options.json {
    let percent = match change {
      Some(value) => value.to_string()
      None => "null"
    }
    let baseline_json = summary(before, true)
    let candidate_json = summary(after, true)
    println(
      "{\"baseline\":\{baseline_json},\"candidate\":\{candidate_json},\"p99_increase_pct\":\{percent},\"threshold_exceeded\":\{exceeded}}",
    )
  } else {
    println("baseline   \{summary(before, false)}")
    println("candidate  \{summary(after, false)}")
    match change {
      Some(percent) => println("P99 change: \{percent}%")
      None => println("P99 change: undefined with a zero baseline")
    }
    if exceeded {
      println("P99 threshold exceeded")
    }
  }
  if exceeded {
    1
  } else {
    0
  }
}

///|
fn run(args : ArrayView[String]) -> Int raise @hloglib.HlogError {
  match args {
    [] | ["--help"] | ["-h"] => {
      println(usage)
      0
    }
    ["summary", path, .. rest] => {
      let options = read_options(rest, false)
      println(summary(selected(path, options), options.json))
      0
    }
    ["compare", a, b, .. rest] => compare(a, b, read_options(rest, true))
    ["rewrite", input, output] => {
      let rewritten = load(input).encode()
      @fs.write_string_to_file(output, rewritten) catch {
        _ => raise @hloglib.Invalid("cannot write \{output}")
      }
      0
    }
    _ => raise @hloglib.Invalid("invalid arguments. Run hlog --help.")
  }
}

///|
fn main {
  let args = @env.args()
  let status = run(args[1:]) catch {
    @hloglib.Invalid(message)
    | @hloglib.Unsupported(message)
    | @hloglib.Incompatible(message) => {
      println("hlog: \{message}")
      2
    }
  }
  if status != 0 {
    @sys.exit(status)
  }
}
