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

///|
test "window groups merge counts and preserve distinct tags" {
  let layout = make_layout(1L, 1000L, 3)
  let histogram : Histogram = {
    layout,
    buckets: [{ index: 40, count: 3L, }],
    total: 3L,
  }
  let payload = histogram.encode()
  let log = parse_log(
    "#[StartTime: 0 (seconds since epoch)]\nTag=read,1.25,1,40,\{payload}\nTag=read,1.75,1,40,\{payload}\nTag=write,1.25,1,40,\{payload}\nTag=read,-0.25,1,40,\{payload}\n1.25,1,40,\{payload}",
  )
  let groups = log.windows(Default::default(), 1.0)
  assert_eq(groups.length(), 4)
  assert_eq(groups[0].tag, None)
  assert_eq(groups[1].index, -1L)
  assert_eq(groups[2].tag, Some("read"))
  assert_eq(groups[2].histogram.count(), 6L)
  assert_eq(groups[3].tag, Some("write"))
  let selection : Selection = {
    tag: Some("read"),
    from: Some(1.25),
    until: Some(1.75),
  }
  let selected = log.windows(selection, 1.0)
  assert_eq(selected.length(), 1)
  assert_eq(selected[0].histogram.count(), 3L)
}

///|
test "window comparison retains missing groups" {
  let layout = make_layout(1L, 1000L, 3)
  let histogram : Histogram = {
    layout,
    buckets: [{ index: 10, count: 2L, }],
    total: 2L,
  }
  let payload = histogram.encode()
  let a = parse_log(
    "#[StartTime: 0 (seconds since epoch)]\nTag=read,0,1,10,\{payload}\nTag=read,1,1,10,\{payload}",
  )
  let b = parse_log(
    "#[StartTime: 0 (seconds since epoch)]\nTag=read,1,1,10,\{payload}\nTag=write,2,1,10,\{payload}",
  )
  let rows = a.compare_windows(b, Default::default(), 1.0)
  assert_eq(rows.length(), 3)
  assert_true(rows[0].baseline is Some(_))
  assert_true(rows[0].candidate is None)
  assert_true(rows[1].baseline is Some(_))
  assert_true(rows[1].candidate is Some(_))
  assert_true(rows[2].baseline is None)
  assert_true(rows[2].candidate is Some(_))
}

///|
test "invalid window size is rejected" {
  let log = parse_log("")
  try log.windows(Default::default(), 0.0) catch {
    Invalid(message) =>
      assert_eq(message, "window size must be finite and positive")
    _ => fail("unexpected error")
  } noraise {
    _ => fail("invalid window accepted")
  }
}

///|
test "identical millisecond timestamps group together across time bases" {
  let layout = make_layout(1L, 1000L, 3)
  let histogram : Histogram = {
    layout,
    buckets: [{ index: 10, count: 2L, }],
    total: 2L,
  }
  let payload = histogram.encode()
  let direct = parse_log(
    "#[StartTime: 1700000000.000 (seconds since epoch)]\nTag=read,0.300,0.100,10,\{payload}\nTag=read,-0.101,0.100,10,\{payload}",
  )
  let anchored = parse_log(
    "#[StartTime: 1700000000.000 (seconds since epoch)]\n#[BaseTime: 1699999990.000 (seconds since epoch)]\nTag=read,10.300,0.100,10,\{payload}\nTag=read,9.899,0.100,10,\{payload}",
  )
  let groups = direct.compare_windows(anchored, Default::default(), 0.1)
  assert_eq(groups.map(row => row.index), [-2L, 3L])
  for group in groups {
    assert_true(group.baseline is Some(_))
    assert_true(group.candidate is Some(_))
  }
  let selection : Selection = {
    tag: Some("read"),
    from: Some(0.3),
    until: None,
  }
  assert_eq(anchored.windows(selection, 0.1).length(), 1)
}

///|
test "incremental parser preserves origin even if initial interval is skipped" {
  let layout = make_layout(1L, 1000L, 3)
  let histogram : Histogram = {
    layout,
    buckets: [{ index: 10, count: 2L, }],
    total: 2L,
  }
  let selection : Selection = {
    tag: Some("read"),
    from: Some(1.0),
    until: Some(2.0),
  }
  let parser = LogParser(selection~, selected_only=true)
  assert_true(parser.push("Tag=write,10,1,10,?") is None)
  guard parser.push("Tag=read,11,1,10,\{histogram.encode()}"[:]) is Some(entry) else {
    fail("selected interval missing")
  }
  assert_eq(entry.relative_start, 1.0)
  assert_eq(entry.histogram.count(), 2L)
  assert_eq(parser.checked_payloads(), 1L)
  assert_eq(parser.skipped_payloads(), 1L)
  try parser.push("#[StartTime: 22 (seconds since epoch)]") catch {
    Invalid(message) =>
      assert_eq(message, "line 3: StartTime must precede data")
    _ => fail("unexpected error")
  } noraise {
    _ => fail("accepted a change of origin after an interval")
  }
}

///|
test "strict incremental parser validates unselected payloads" {
  let selection : Selection = { tag: Some("read"), from: None, until: None, }
  let parser = LogParser(selection~)
  try parser.push("Tag=write,0,1,10,?") catch {
    Invalid(message) =>
      assert_eq(message, "line 1: invalid base64 histogram payload")
    _ => fail("unexpected error")
  } noraise {
    _ => fail("strict parser skipped a malformed payload")
  }
}
