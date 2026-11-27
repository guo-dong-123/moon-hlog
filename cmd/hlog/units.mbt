///|
fn read_unit(value : String) -> String raise @hloglib.HlogError {
  match value {
    "ns" | "us" | "ms" | "s" => value
    _ => raise @hloglib.Invalid("latency unit must be ns, us, ms, or s")
  }
}

///|
fn units_mismatch(options : Options) -> Bool {
  options.baseline_unit != options.candidate_unit
}

///|
fn units_json_suffix(options : Options) -> String {
  match (options.baseline_unit, options.candidate_unit) {
    (Some(baseline), Some(candidate)) =>
      ",\"units\":{\"baseline\":\"\{baseline}\",\"candidate\":\"\{candidate}\"}"
    _ => ""
  }
}

///|
fn explain_units(options : Options) -> Unit {
  if options.baseline_unit is Some(unit) {
    println("Declared latency unit: \{unit}")
  }
}

///|
fn report_units_mismatch(options : Options) -> Unit {
  if options.json {
    let units = units_json_suffix(options)
    println(
      "{\"gate_failed\":true,\"outcome\":\"incomparable\",\"reason\":\"unit_mismatch\"\{units}}",
    )
  } else {
    let before = options.baseline_unit.unwrap_or("unknown")
    let after = options.candidate_unit.unwrap_or("unknown")
    println(
      "Incomparable input: baseline unit \{before}, candidate unit \{after}",
    )
  }
}
