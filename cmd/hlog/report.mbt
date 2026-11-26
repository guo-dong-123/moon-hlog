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
fn p99(histogram : @hloglib.Histogram?) -> Int64? {
  match histogram {
    Some(value) => value.percentile(9900)
    None => None
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
fn report(
  baseline : String,
  candidate : String,
  options : Options,
) -> Int raise @hloglib.HlogError {
  guard options.window is Some(seconds) else {
    raise @hloglib.Invalid("report requires --window SECONDS")
  }
  let selection : @hloglib.Selection = {
    tag: options.tag,
    from: options.from,
    until: options.until,
  }
  let rows = load(baseline).compare_windows(load(candidate), selection, seconds)
  if rows.is_empty() {
    raise @hloglib.Invalid("no intervals match the selection")
  }
  let json_rows : Array[String] = []
  let mut failed = false
  for row in rows {
    let before = p99(row.baseline)
    let after = p99(row.candidate)
    let (change, status) = match (before, after) {
      (Some(a), Some(b)) => {
        let change = if a == 0L {
          None
        } else {
          Some((b - a).to_double() * 100.0 / a.to_double())
        }
        let exceeds = match options.max_increase {
          None => false
          Some(limit) =>
            match change {
              None => b > 0L
              Some(percent) => percent > limit
            }
        }
        if exceeds {
          failed = true
        }
        (change, if exceeds { "regression" } else { "compared" })
      }
      (None, None) => (None, "no_samples")
      (None, Some(_)) => (None, "missing_baseline_samples")
      (Some(_), None) => (None, "missing_candidate_samples")
    }
    if (before is None || after is None) && options.max_increase is Some(_) {
      failed = true
    }
    let start = row.index.to_double() * seconds
    let end = (row.index.to_double() + 1.0) * seconds
    let tag_json = match row.tag {
      Some(tag) => Json::string(tag).stringify()
      None => "null"
    }
    if options.json {
      let base = histogram_json(row.baseline)
      let next = histogram_json(row.candidate)
      let percent = json_number(change)
      json_rows.push(
        "{\"tag\":\{tag_json},\"window_start\":\{start},\"window_end\":\{end},\"baseline\":\{base},\"candidate\":\{next},\"p99_increase_pct\":\{percent},\"status\":\"\{status}\"}",
      )
    } else {
      let base = match before {
        Some(value) => value.to_string()
        None => "-"
      }
      let next = match after {
        Some(value) => value.to_string()
        None => "-"
      }
      println(
        "tag=\{tag_json}  [\{start}, \{end})  P99=\{base} -> \{next}  \{status}",
      )
    }
  }
  if options.json {
    let rows_json = json_rows.join(",")
    println(
      "{\"window_seconds\":\{seconds},\"rows\":[\{rows_json}],\"gate_failed\":\{failed}}",
    )
  }
  if failed {
    1
  } else {
    0
  }
}
