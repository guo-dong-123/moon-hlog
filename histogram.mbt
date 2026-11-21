///|
/// Errors describing malformed data, unsupported formats, or invalid operations.
pub(all) suberror HlogError {
  Invalid(String)
  Unsupported(String)
  Incompatible(String)
} derive(Debug)

///|
priv struct Layout {
  lowest : Int64
  highest : Int64
  digits : Int
  unit_magnitude : Int
  half_magnitude : Int
  count_limit : Int
}

///|
priv struct Bucket {
  index : Int
  count : Int64
}

///|
/// An integer HdrHistogram with sorted, sparse logical buckets.
pub struct Histogram {
  priv layout : Layout
  priv buckets : Array[Bucket]
  priv total : Int64
}

///|
fn make_layout(
  lowest : Int64,
  highest : Int64,
  digits : Int,
) -> Layout raise HlogError {
  if lowest < 1L || lowest > highest / 2L || digits < 0 || digits > 5 {
    raise Invalid("invalid histogram precision or value range")
  }
  let mut sub_bucket_size = 2L
  for _ in 0..<digits {
    sub_bucket_size *= 10L
  }
  let half_magnitude = 63 - (sub_bucket_size - 1L).clz()
  let unit_magnitude = 63 - lowest.clz()
  if unit_magnitude + half_magnitude > 61 {
    raise Invalid("histogram bucket layout exceeds the signed integer range")
  }
  let last_bucket = (63 - highest.clz() - unit_magnitude - half_magnitude).max(
    0,
  )
  {
    lowest,
    highest,
    digits,
    unit_magnitude,
    half_magnitude,
    count_limit: (last_bucket + 2) * (1 << half_magnitude),
  }
}

///|
fn checked_count_add(a : Int64, b : Int64) -> Int64 raise HlogError {
  if b > 9223372036854775807L - a {
    raise Invalid("histogram sample count exceeds Int64")
  }
  a + b
}

///|
fn bucket_value(layout : Layout, index : Int, upper : Bool) -> Int64 {
  let half = 1 << layout.half_magnitude
  let bucket = ((index >> layout.half_magnitude) - 1).max(0)
  let sub_bucket = if index < 2 * half {
    index
  } else {
    (index & (half - 1)) + half
  }
  let magnitude = bucket + layout.unit_magnitude
  let lower = sub_bucket.to_int64() << magnitude
  if upper {
    lower | ((1L << magnitude) - 1L)
  } else {
    lower
  }
}

///|
/// Returns the number of samples represented by the histogram.
pub fn Histogram::count(self : Histogram) -> Int64 {
  self.total
}

///|
/// Returns a percentile in the histogram's native units.
/// The 0 to 10,000 basis-point scale represents 0% to 100%.
pub fn Histogram::percentile(self : Histogram, basis_points : Int) -> Int64? {
  if self.total == 0L || basis_points < 0 || basis_points > 10000 {
    return None
  }
  let bp = basis_points.to_int64()
  let rank = (self.total / 10000L * bp +
  (self.total % 10000L * bp + 9999L) / 10000L).max(1L)
  let mut cumulative = 0L
  for bucket in self.buckets {
    cumulative += bucket.count
    if cumulative >= rank {
      return Some(bucket_value(self.layout, bucket.index, basis_points > 0))
    }
  }
  None
}

///|
/// Merges sample counts for compatible integer bucket layouts.
pub fn Histogram::merge(
  self : Histogram,
  other : Histogram,
) -> Histogram raise HlogError {
  if self.total == 0L {
    return other
  }
  if other.total == 0L {
    return self
  }
  if self.layout.unit_magnitude != other.layout.unit_magnitude ||
    self.layout.digits != other.layout.digits {
    raise Incompatible("histograms have different bucket layouts")
  }
  let total = checked_count_add(self.total, other.total)
  let layout = if self.layout.highest >= other.layout.highest {
    self.layout
  } else {
    other.layout
  }
  let buckets : Array[Bucket] = []
  let mut left = 0
  let mut right = 0
  while left < self.buckets.length() && right < other.buckets.length() {
    let a = self.buckets[left]
    let b = other.buckets[right]
    if a.index == b.index {
      buckets.push({ index: a.index, count: a.count + b.count, })
      left += 1
      right += 1
    } else if a.index < b.index {
      buckets.push(a)
      left += 1
    } else {
      buckets.push(b)
      right += 1
    }
  }
  for i in left..<self.buckets.length() {
    buckets.push(self.buckets[i])
  }
  for i in right..<other.buckets.length() {
    buckets.push(other.buckets[i])
  }
  { layout, buckets, total, }
}
