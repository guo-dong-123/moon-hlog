///|
let usage : String =
  #|MoonHlog
  #|  hlog summary LOG [--tag TAG] [--from SECONDS] [--until SECONDS] [--json]
  #|  hlog compare BASELINE CANDIDATE [--tag TAG] [--from SECONDS] [--until SECONDS]
  #|               [--max-p99-increase-pct PCT] [--min-samples COUNT] [--json]
  #|  hlog report BASELINE CANDIDATE --window SECONDS [--tag TAG] [--from SECONDS]
  #|               [--until SECONDS] [--max-p99-increase-pct PCT] [--min-samples COUNT] [--json]
  #|  hlog rewrite INPUT OUTPUT
  #|
  #|Window bounds use interval start time relative to each log's StartTime.
  #|Optional --selected-only skips compressed payloads outside the selection.
  #|Compare/report: --baseline-unit UNIT --candidate-unit UNIT (ns, us, ms, s).
  #|Histogram values use the producer's native units.

///|
struct Options {
  mut tag : String?
  mut from : Double?
  mut until : Double?
  mut max_increase : Double?
  mut min_samples : Int64?
  mut json : Bool
  mut window : Double?
  mut selected_only : Bool
  mut baseline_unit : String?
  mut candidate_unit : String?
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
  command : String,
) -> Options raise @hloglib.HlogError {
  let options : Options = {
    tag: None,
    from: None,
    until: None,
    max_increase: None,
    min_samples: None,
    json: false,
    window: None,
    selected_only: false,
    baseline_unit: None,
    candidate_unit: None,
  }
  for i = 0; i < args.length(); {
    let flag = args[i]
    if flag == "--json" {
      options.json = true
      continue i + 1
    }
    if flag == "--selected-only" {
      options.selected_only = true
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
      "--max-p99-increase-pct" if command != "summary" => {
        let percent = read_number(flag, value)
        if percent < 0.0 {
          raise @hloglib.Invalid("max P99 increase must be nonnegative")
        }
        options.max_increase = Some(percent)
      }
      "--min-samples" if command != "summary" => {
        let count = @string.parse_int64(value[:], base=10) catch {
          _ =>
            raise @hloglib.Invalid("--min-samples requires a positive integer")
        }
        if count <= 0L {
          raise @hloglib.Invalid("--min-samples requires a positive integer")
        }
        options.min_samples = Some(count)
      }
      "--baseline-unit" if command != "summary" =>
        options.baseline_unit = Some(read_unit(value))
      "--candidate-unit" if command != "summary" =>
        options.candidate_unit = Some(read_unit(value))
      "--window" if command == "report" => {
        let seconds = read_number(flag, value)
        if seconds <= 0.0 {
          raise @hloglib.Invalid("window size must be positive")
        }
        options.window = Some(seconds)
      }
      _ =>
        raise @hloglib.Invalid("unrecognized option or invalid value: \{flag}")
    }
    continue i + 2
  }
  if (options.baseline_unit is None) != (options.candidate_unit is None) {
    raise @hloglib.Invalid("declare both --baseline-unit and --candidate-unit")
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
fn histogram_json(histogram : @hloglib.Histogram?) -> String {
  match histogram {
    Some(value) if value.count() > 0L => summary(value, true)
    Some(value) =>
      "{\"samples\":\{value.count()},\"p50\":null,\"p95\":null,\"p99\":null,\"p999\":null}"
    None => "null"
  }
}

///|
fn json_number(value : Double?) -> String {
  match value {
    Some(n) => n.to_string()
    None => "null"
  }
}

///|
fn minimum_json(options : Options) -> String {
  match options.min_samples {
    Some(count) => count.to_string()
    None => "null"
  }
}

///|
async fn compare(
  baseline : String,
  candidate : String,
  options : Options,
) -> Int raise @hloglib.HlogError {
  if units_mismatch(options) {
    report_units_mismatch(options)
    return 2
  }
  let baseline_input = selected_histogram(baseline, options)
  if options.min_samples is None {
    ignore(require_samples(baseline, baseline_input))
  }
  let candidate_input = selected_histogram(candidate, options)
  let (before, after) = if options.min_samples is Some(_) {
    (baseline_input.histogram, candidate_input.histogram)
  } else {
    (
      Some(require_samples(baseline, baseline_input)),
      Some(require_samples(candidate, candidate_input)),
    )
  }
  let decision = evaluate_gate(before, after, options)
  let failed = decision.outcome.blocks(options)
  if options.json {
    let percent = json_number(decision.change)
    let baseline_json = histogram_json(before)
    let candidate_json = histogram_json(after)
    let exceeded = decision.outcome == Regression
    let outcome = decision.outcome.label()
    let minimum = minimum_json(options)
    let units = units_json_suffix(options)
    let validation = if options.selected_only {
      ",\"validation\":\{comparison_validation_json(baseline_input.stats, candidate_input.stats)}"
    } else {
      ""
    }
    println(
      "{\"baseline\":\{baseline_json},\"candidate\":\{candidate_json},\"p99_increase_pct\":\{percent},\"threshold_exceeded\":\{exceeded},\"gate_failed\":\{failed},\"min_samples\":\{minimum},\"outcome\":\"\{outcome}\",\"reason\":\"\{decision.reason}\"\{units}\{validation}}",
    )
  } else {
    let before_text = match before {
      Some(histogram) if histogram.count() > 0L => summary(histogram, false)
      _ => "no samples"
    }
    let after_text = match after {
      Some(histogram) if histogram.count() > 0L => summary(histogram, false)
      _ => "no samples"
    }
    explain_units(options)
    println("baseline   \{before_text}")
    println("candidate  \{after_text}")
    if options.selected_only {
      explain_validation(baseline, baseline_input.stats)
      explain_validation(candidate, candidate_input.stats)
    }
    match decision.change {
      Some(percent) => println("P99 change: \{percent}%")
      None if decision.baseline_p99 is Some(0L) &&
        decision.candidate_p99 is Some(_) =>
        println("P99 change: undefined with a zero baseline")
      None => ()
    }
    if decision.outcome == Regression {
      println("P99 threshold exceeded")
    } else if decision.outcome == InsufficientData {
      println("Insufficient data: \{decision.reason}")
    }
  }
  if failed {
    1
  } else {
    0
  }
}

///|
async fn run(args : ArrayView[String]) -> Int raise @hloglib.HlogError {
  match args {
    [] | ["--help"] | ["-h"] => {
      println(usage)
      0
    }
    ["summary", path, .. rest] => {
      let options = read_options(rest, "summary")
      let selected = selected_histogram(path, options)
      let result = summary(require_samples(path, selected), options.json)
      if options.selected_only && options.json {
        let validation = stats_json(selected.stats)
        let prefix = result[:result.length() - 1].to_owned()
        println("\{prefix},\"validation\":\{validation}}")
      } else {
        println(result)
        if options.selected_only {
          explain_validation(path, selected.stats)
        }
      }
      0
    }
    ["compare", a, b, .. rest] => compare(a, b, read_options(rest, "compare"))
    ["report", a, b, .. rest] => report(a, b, read_options(rest, "report"))
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
async fn main {
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
