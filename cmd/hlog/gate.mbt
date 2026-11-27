///|
// Declaration order also defines which result represents a multi-window report.
enum GateOutcome {
  NotEvaluated
  Pass
  InsufficientData
  Regression
} derive(Eq, Compare)

///|
fn GateOutcome::label(self : GateOutcome) -> String {
  match self {
    NotEvaluated => "not_evaluated"
    Pass => "pass"
    InsufficientData => "insufficient_data"
    Regression => "regression"
  }
}

///|
fn GateOutcome::blocks(self : GateOutcome, options : Options) -> Bool {
  self == Regression ||
  (
    self == InsufficientData &&
    (options.min_samples is Some(_) || options.max_increase is Some(_))
  )
}

///|
struct GateDecision {
  outcome : GateOutcome
  reason : String
  change : Double?
  baseline_p99 : Int64?
  candidate_p99 : Int64?
}

///|
fn p99(histogram : @hloglib.Histogram?) -> Int64? {
  match histogram {
    Some(value) => value.percentile(9900)
    None => None
  }
}

///|
fn sample_count(histogram : @hloglib.Histogram?) -> Int64 {
  match histogram {
    Some(value) => value.count()
    None => 0L
  }
}

///|
fn evaluate_gate(
  baseline : @hloglib.Histogram?,
  candidate : @hloglib.Histogram?,
  options : Options,
) -> GateDecision {
  let baseline_p99 = p99(baseline)
  let candidate_p99 = p99(candidate)
  let (outcome, reason, change) = match (baseline_p99, candidate_p99) {
    (Some(prior), Some(current)) => {
      let change = if prior == 0L {
        None
      } else {
        Some((current - prior).to_double() * 100.0 / prior.to_double())
      }
      let (outcome, reason) = if options.min_samples is Some(minimum) &&
        (sample_count(baseline) < minimum || sample_count(candidate) < minimum) {
        (InsufficientData, "below_min_samples")
      } else if options.max_increase is Some(limit) {
        let exceeded = match change {
          None => current > 0L
          Some(percent) => percent > limit
        }
        if exceeded {
          (Regression, "p99_threshold_exceeded")
        } else {
          (Pass, "thresholds_met")
        }
      } else if options.min_samples is Some(_) {
        (Pass, "thresholds_met")
      } else {
        (NotEvaluated, "no_gate_configured")
      }
      (outcome, reason, change)
    }
    (None, None) => (InsufficientData, "no_samples", None)
    (None, Some(_)) => (InsufficientData, "missing_baseline_samples", None)
    (Some(_), None) => (InsufficientData, "missing_candidate_samples", None)
  }
  { outcome, reason, change, baseline_p99, candidate_p99, }
}
