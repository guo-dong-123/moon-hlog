///|
fn boundary(index : Int64, seconds : Double) -> Double {
  let milliseconds = (seconds * 1000.0).round()
  let scaled = index.to_double() * milliseconds
  if milliseconds / 1000.0 == seconds && scaled.abs() <= 9007199254740991.0 {
    scaled / 1000.0
  } else {
    index.to_double() * seconds
  }
}

///|
async fn report(
  baseline : String,
  candidate : String,
  options : Options,
) -> Int raise @hloglib.HlogError {
  guard options.window is Some(seconds) else {
    raise @hloglib.Invalid("report requires --window SECONDS")
  }
  if units_mismatch(options) {
    report_units_mismatch(options)
    return 2
  }
  let (baseline_windows, baseline_stats) = read_windows(
    baseline, options, seconds,
  )
  let (candidate_windows, candidate_stats) = read_windows(
    candidate, options, seconds,
  )
  let rows = baseline_windows.compare(candidate_windows)
  if rows.is_empty() && options.min_samples is None {
    raise @hloglib.Invalid("no intervals match the selection")
  }
  let json_rows : Array[String] = []
  let mut outcome : GateOutcome = if rows.is_empty() {
    InsufficientData
  } else {
    NotEvaluated
  }
  for row in rows {
    let decision = evaluate_gate(row.baseline, row.candidate, options)
    if decision.outcome > outcome {
      outcome = decision.outcome
    }
    let status = match decision.outcome {
      NotEvaluated | Pass => "compared"
      Regression => "regression"
      InsufficientData => decision.reason
    }
    let start = boundary(row.index, seconds)
    let end = boundary(row.index + 1L, seconds)
    let tag_json = match row.tag {
      Some(tag) => Json::string(tag).stringify()
      None => "null"
    }
    if options.json {
      let base = histogram_json(row.baseline)
      let next = histogram_json(row.candidate)
      let percent = json_number(decision.change)
      let row_outcome = decision.outcome.label()
      json_rows.push(
        "{\"tag\":\{tag_json},\"window_start\":\{start},\"window_end\":\{end},\"baseline\":\{base},\"candidate\":\{next},\"p99_increase_pct\":\{percent},\"status\":\"\{status}\",\"outcome\":\"\{row_outcome}\",\"reason\":\"\{decision.reason}\"}",
      )
    } else {
      let base = match decision.baseline_p99 {
        Some(value) => value.to_string()
        None => "-"
      }
      let next = match decision.candidate_p99 {
        Some(value) => value.to_string()
        None => "-"
      }
      println(
        "tag=\{tag_json}  [\{start}, \{end})  P99=\{base} -> \{next}  \{status}",
      )
    }
  }
  let failed = outcome.blocks(options)
  let reason = match outcome {
    NotEvaluated => "no_gate_configured"
    Pass => "thresholds_met"
    Regression => "window_regression"
    InsufficientData if rows.is_empty() => "no_matching_intervals"
    InsufficientData => "window_insufficient_data"
  }
  if options.json {
    let report_outcome = outcome.label()
    let minimum = minimum_json(options)
    let rows_json = json_rows.join(",")
    let units = units_json_suffix(options)
    let validation = if options.selected_only {
      ",\"validation\":\{comparison_validation_json(baseline_stats, candidate_stats)}"
    } else {
      ""
    }
    println(
      "{\"window_seconds\":\{seconds},\"rows\":[\{rows_json}],\"gate_failed\":\{failed},\"min_samples\":\{minimum},\"outcome\":\"\{report_outcome}\",\"reason\":\"\{reason}\"\{units}\{validation}}",
    )
  } else if rows.is_empty() {
    println("Insufficient data: \{reason}")
  }
  if !options.json {
    explain_units(options)
  }
  if options.selected_only && !options.json {
    explain_validation(baseline, baseline_stats)
    explain_validation(candidate, candidate_stats)
  }
  if failed {
    1
  } else {
    0
  }
}
