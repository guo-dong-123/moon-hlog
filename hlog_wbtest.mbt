///|
test "V2 counts round-trip across the 9-byte boundary" {
  let output = @buffer.Buffer()
  for
    value in [
      -9223372036854775807L - 1L,
      -128L,
      -1L,
      0L,
      63L,
      64L,
      36028797018963968L,
      4611686018427387904L,
      9223372036854775807L,
    ] {
    write_count(output, value)
  }
  let encoded = output.to_bytes()
  let mut offset = 0
  for
    expected in [
      -9223372036854775807L - 1L,
      -128L,
      -1L,
      0L,
      63L,
      64L,
      36028797018963968L,
      4611686018427387904L,
      9223372036854775807L,
    ] {
    let (value, next) = read_count(encoded[:], offset)
    assert_eq(value, expected)
    offset = next
  }
  assert_eq(offset, encoded.length())
}

///|
test "a count must terminate within the frame" {
  try read_count(b"\xff"[:], 0) catch {
    Invalid(message) =>
      assert_eq(message, "truncated count in histogram payload")
    _ => fail("unexpected error variant")
  } noraise {
    _ => fail("unterminated count accepted")
  }
}

///|
test "aggregate percentile uses all sample counts" {
  let layout = make_layout(1L, 1000L, 3)
  let low : Histogram = {
    layout,
    buckets: [{ index: 1, count: 980L, }],
    total: 980L,
  }
  let high : Histogram = {
    layout,
    buckets: [{ index: 999, count: 20L, }],
    total: 20L,
  }
  let merged = low.merge(high)
  assert_eq(merged.count(), 1000L)
  assert_eq(merged.percentile(9900), Some(999L))
  assert_eq(merged.percentile(9500), Some(1L))
}

///|
test "highest configured bucket can hold its full range" {
  let layout = make_layout(1L, 2048L, 3)
  assert_eq(layout.count_limit, 3072)
  assert_eq(bucket_value(layout, 2048, false), 2048L)
  assert_eq(bucket_value(layout, 2048, true), 2049L)
  let original : Histogram = {
    layout,
    buckets: [{ index: 2048, count: 1L, }],
    total: 1L,
  }
  let decoded = decode_histogram(original.encode()[:])
  assert_eq(decoded.percentile(0), Some(2048L))
  assert_eq(decoded.percentile(10000), Some(2049L))
}

///|
test "frame inflation advances through multiple output chunks" {
  let raw = @buffer.Buffer()
  for i in 0..<50000 {
    raw.write_byte((i % 259 % 256).to_byte())
  }
  let expected = raw.to_bytes()
  let compressed = @zlib.zlib_compress(expected)
  assert_eq(inflate_frame(compressed[:]), expected)
}

///|
test "log reports original line number on malformed input" {
  try parse_log("# comment\n\n1.0,2.0,0.0,?\n") catch {
    Invalid(message) =>
      assert_eq(message, "line 3: invalid base64 histogram payload")
    _ => fail("unexpected error variant")
  } noraise {
    _ => fail("malformed payload accepted")
  }
}

///|
test "an empty log and an invalid window are distinct" {
  let log = parse_log("#[StartTime: 1000 (seconds since epoch)]")
  assert_true(log.aggregate(Default::default()) is None)
  let invalid : Selection = { tag: None, from: Some(4.0), until: Some(3.0), }
  try log.aggregate(invalid) catch {
    Invalid(message) => assert_eq(message, "window start must precede end")
    _ => fail("unexpected error variant")
  } noraise {
    _ => fail("reversed window accepted")
  }
}

///|
test "check for overflow when adding counts" {
  let layout = make_layout(1L, 1000L, 3)
  let count = 9223372036854775807L
  let left : Histogram = {
    layout,
    buckets: [{ index: 1, count, }],
    total: count,
  }
  let right : Histogram = {
    layout,
    buckets: [{ index: 1, count: 1L, }],
    total: 1L,
  }
  try left.merge(right) catch {
    Invalid(message) =>
      assert_eq(message, "histogram sample count exceeds Int64")
    _ => fail("unexpected error variant")
  } noraise {
    _ => fail("overflow accepted")
  }
}

///|
test "rewrite preserves the declared peak and supports an empty tag" {
  let layout = make_layout(1L, 1000L, 3)
  let histogram : Histogram = {
    layout,
    buckets: [{ index: 40, count: 1L, }],
    total: 1L,
  }
  let payload = histogram.encode()
  let log = parse_log("Tag=,1.0,2.0,40.000,\{payload}"[:])
  assert_eq(log.intervals()[0].tag, Some(""))
  assert_true(log.encode().contains(",40.000,"))
  try parse_log("Tag=invalid tag,1.0,2.0,40.000,\{payload}"[:]) catch {
    Invalid(message) =>
      assert_eq(message, "line 1: histogram tag contains a delimiter")
    _ => fail("unexpected error variant")
  } noraise {
    _ => fail("tag delimiter accepted")
  }
}
