///|
let compressed_cookie : Int = 0x1c849314

///|
let integer_cookie : Int = 0x1c849313

///|
let max_frame_bytes : Int = 8 * 1024 * 1024

///|
fn read_int(data : BytesView, index : Int, width : Int) -> Int64 {
  let mut value = 0L
  for i in index..<(index + width) {
    value = (value << 8) | data[i].to_int64()
  }
  value
}

///|
fn inflate_frame(data : BytesView) -> Bytes raise HlogError {
  let decoder = @zlib.Decoder::new()
  let chunk = Array::make(16384, b'\x00')
  let output = @buffer.Buffer()
  let mut offset = 0
  while true {
    let status = decoder.step(data[offset:], chunk.mut_view(), end=true) catch {
      _ => raise Invalid("invalid zlib histogram payload")
    }
    let produced = decoder.last_produced()
    let consumed = decoder.last_consumed()
    if output.length() + produced > max_frame_bytes {
      raise Invalid("inflated histogram exceeds 8 MiB")
    }
    for i in 0..<produced {
      output.write_byte(chunk[i])
    }
    offset += consumed
    match status {
      @flate.Done => {
        if offset != data.length() || decoder.unused_input().length() != 0 {
          raise Invalid("trailing bytes after zlib stream")
        }
        return output.to_bytes()
      }
      @flate.NeedMoreInput => raise Invalid("truncated zlib histogram payload")
      @flate.NeedMoreOutput =>
        if produced == 0 && consumed == 0 {
          raise Invalid("zlib decoder made no progress")
        }
    }
  }
  output.to_bytes()
}

///|
// The ninth byte carries all eight remaining bits in HdrHistogram V2.
fn read_count(data : BytesView, offset : Int) -> (Int64, Int) raise HlogError {
  let mut packed = 0UL
  for i in 0..<9 {
    let pos = offset + i
    if pos >= data.length() {
      raise Invalid("truncated count in histogram payload")
    }
    let byte = data[pos].to_uint64()
    if i == 8 || byte < 128UL {
      packed = packed | (byte << (7 * i))
      let signed = (packed >> 1).reinterpret_as_int64() ^
        -(packed & 1UL).reinterpret_as_int64()
      return (signed, pos + 1)
    }
    packed = packed | ((byte & 127UL) << (7 * i))
  }
  raise Invalid("invalid histogram count")
}

///|
fn write_count(output : @buffer.Buffer, value : Int64) -> Unit {
  let mut packed = ((value << 1) ^ (value >> 63)).reinterpret_as_uint64()
  for _ in 0..<8 {
    if packed < 128UL {
      output.write_byte(packed.to_byte())
      return
    }
    output.write_byte(((packed & 127UL) | 128UL).to_byte())
    packed = packed >> 7
  }
  output.write_byte(packed.to_byte())
}

///|
/// Decodes one base64-encoded, zlib-compressed HdrHistogram V2 integer frame.
pub fn decode_histogram(payload : StringView) -> Histogram raise HlogError {
  if payload.length() > (max_frame_bytes + 8) * 4 / 3 + 4 {
    raise Invalid("encoded histogram exceeds size limit")
  }
  let encoded = @base64.decode(payload) catch {
    _ => raise Invalid("invalid base64 histogram payload")
  }
  let outer = encoded[:]
  if outer.length() < 8 {
    raise Invalid("truncated outer histogram header")
  }
  if read_int(outer, 0, 4) != compressed_cookie.to_int64() {
    raise Unsupported("expected a V2 compressed integer histogram")
  }
  if read_int(outer, 4, 4) != (outer.length() - 8).to_int64() {
    raise Invalid("compressed histogram length mismatch")
  }
  let bytes = inflate_frame(outer[8:])
  let data = bytes[:]
  if data.length() < 40 {
    raise Invalid("truncated inner histogram header")
  }
  if read_int(data, 0, 4) != integer_cookie.to_int64() {
    raise Unsupported("expected a V2 integer histogram payload")
  }
  if read_int(data, 4, 4) != (data.length() - 40).to_int64() {
    raise Invalid("histogram counts length mismatch")
  }
  if read_int(data, 8, 4) != 0L || read_int(data, 32, 8) != 0x3ff0000000000000L {
    raise Unsupported("histogram normalization offset or scale is unsupported")
  }
  let digits = read_int(data, 12, 4)
  if digits > 5L {
    raise Invalid("invalid number of significant digits")
  }
  let layout = make_layout(
    read_int(data, 16, 8),
    read_int(data, 24, 8),
    digits.to_int(),
  )
  let buckets : Array[Bucket] = []
  let mut total = 0L
  let mut cursor = 40
  let mut index = 0
  while cursor < data.length() {
    let (value, next) = read_count(data, cursor)
    cursor = next
    if value < 0L {
      if value < -(layout.count_limit - index).to_int64() {
        raise Invalid("zero run exceeds the histogram layout")
      }
      index += (-value).to_int()
    } else {
      if index >= layout.count_limit {
        raise Invalid("count exceeds the histogram layout")
      }
      if value > 0L {
        total = checked_count_add(total, value)
        buckets.push({ index, count: value, })
      }
      index += 1
    }
  }
  { layout, buckets, total, }
}

///|
/// Encodes a histogram as a compressed integer frame accepted by HdrHistogram.
pub fn Histogram::encode(self : Histogram) -> String raise HlogError {
  let counts = @buffer.Buffer()
  let mut index = 0
  for bucket in self.buckets {
    let gap = bucket.index - index
    if gap > 0 {
      write_count(counts, -gap.to_int64())
    }
    write_count(counts, bucket.count)
    index = bucket.index + 1
  }
  if index == 0 {
    write_count(counts, 0L)
  }
  if counts.length() > max_frame_bytes - 40 {
    raise Invalid("encoded counts exceed the frame size limit")
  }
  let inner = @buffer.Buffer()
  inner.write_int_be(integer_cookie)
  inner.write_int_be(counts.length())
  inner.write_int_be(0)
  inner.write_int_be(self.layout.digits)
  inner.write_int64_be(self.layout.lowest)
  inner.write_int64_be(self.layout.highest)
  inner.write_int64_be(0x3ff0000000000000L)
  inner.write_bytes(counts.to_bytes()[:])
  let compressed = @zlib.zlib_compress(inner.to_bytes())
  let outer = @buffer.Buffer()
  outer.write_int_be(compressed_cookie)
  outer.write_int_be(compressed.length())
  outer.write_bytes(compressed[:])
  @base64.encode(outer.to_bytes()[:])
}
