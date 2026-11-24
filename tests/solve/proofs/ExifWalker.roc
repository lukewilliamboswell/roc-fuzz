## The guards of roc-pdf's Exif orientation walker, and the check in its
## caller that they silently depend on.
##
## `inspect_exif_orientation` in roc-pdf `package/KernelImage.roc`, lines 438
## to 501 as of roc-pdf 0d4f3ee, walks a TIFF directory inside a JPEG APP1
## segment. It is handed `start` and `length` and reads `bytes` through
## `list_at`, which crashes on a bad index. Three guards stand between the two
## numbers and those reads.
##
## ## The claim
##
## Whenever the guards pass, no `U64` arithmetic in the walker overflows and
## every index it reads is below `bytes.len()`.
##
## ## What is established
##
## - The claim holds for every 64-bit `start`, `length` and `bytes.len()`,
##   every directory offset and entry count the bytes can hold, and every turn
##   of the loop, given two things about the call: the segment lies inside the
##   bytes (`segment_lies_inside`), and `length >= 6`.
## - Given only the first, the walker `Crashes`, with `start`, `length` and
##   `bytes.len()` all zero. Line 442 subtracts `start + 6` from
##   `start + length`. Under `segment_lies_inside` the first three lines crash
##   exactly when `length < 6`, which is `Proved`.
## - The walker never tests `length >= 6`. Its one caller does, on line 250,
##   as the first half of the test for the `Exif` prefix:
##   `data_length >= 6 and matches(..)`. The caller's earlier guards, lines 178
##   to 187, hand over a segment inside the bytes: `Proved` for every list
##   shorter than 2^64 - 1 bytes, and `Crashes` at exactly that length.
## - `inspect_frame`, the walker next to it, tests `length < 6` itself on line
##   299. Its first reads are `Proved` safe from `segment_lies_inside` alone.
##
## So today's code is safe, and the Exif walker is safe only because of a
## comparison in another function that reads as part of a prefix test. Called
## on any APP1 segment shorter than six bytes it would crash. The real
## function was run to confirm it: with the `expect` appended to a copy of
## roc-pdf's `KernelImage.roc`, `inspect_exif_orientation([], 0, 0, 7)` stops
## with "Integer subtraction overflowed" under Roc 0.1.0_RC1.
##
## ## How it is proved
##
## Asked as one question (`walk(..).is_safe` for all six numbers), the claim
## was too much for the solver: no answer after ten minutes of solving under
## `--opt=speed`. It is cut at three points instead. Each stage is proved from
## what the stage before leaves behind, for every value of the numbers it is
## handed:
##
## 1. `header_is_safe`: the caller's two facts give safe header reads and
##    `after_header`.
## 2. `directory_is_safe`: `after_header` gives a safe count read and
##    `after_directory`.
## 3. `products_are_safe`: any turn of the loop ends inside the entry table.
## 4. `entries_are_safe`: `after_directory` and a turn inside the table give
##    safe entry reads.
##
## The same Roc function states a fact where it is concluded and where it is
## assumed, and `walk` joins the stage functions the way the code joins them.
## That the four lemmas add up to the claim is an argument made in this
## comment. The solver did not check it.
##
## ## What is not established
##
## - The bytes are not modelled. `offset` and `count` are any numbers of their
##   width, and every branch on other bytes is assumed to go the way that
##   reads more.
## - Each stage lists only its furthest read: `tiff + 7`, `ifd + 1` and
##   `entry + 9`. That these are the furthest is from reading the code.
## - The terms are hand-written from the code. The tests at the bottom run a
##   copy of the real function and the term on 4,608 segments, in lists that
##   end where the segment ends, and require the same answer. They would not
##   notice a read the term forgot unless it left the segment.
## - `segment` and `frame_is_safe` restate lines of `inspect_jpeg` and
##   `inspect_frame` by hand. No test compares them with the code.
## - `Proved` rests on the solver finding nothing.
##
## ## What runs here
##
## Only the answers that `roc test` gives in seconds on the default backend:
## the two `Crashes` of `header_is_safe` and the tests that tie the term to
## the copy. The proofs of the four stages, of `header_crashes_exactly_below_six`,
## of the caller and of `inspect_frame` each take from over a minute to
## several minutes there, so they are not asked. Their functions stay, to be
## asked under `--opt=speed`.
import fuzz.Solve

ExifWalker := [].{
	# -- The real code, copied ------------------------------------------------

	Orientation : [BottomLeft, BottomRight, LeftBottom, LeftTop, RightBottom, RightTop, TopLeft, TopRight]

	## Lines 438 to 501 of roc-pdf `package/KernelImage.roc`. Only the two type
	## names in the annotation differ: they belong to modules this file does
	## not have.
	inspect_exif_orientation : List(U8), U64, U64, U64 -> Try([Exif(Orientation), NoExif], [InvalidExif({ resource : U64 })])
	inspect_exif_orientation = |bytes, start, length, resource| {
		tiff = start + 6
		end = start + length
		if end - tiff < 8 {
			Err(
				InvalidExif({
					resource: resource,
				}),
			)
		} else {
			little = list_at(bytes, tiff) == 0x49 and list_at(bytes, tiff + 1) == 0x49
			big = list_at(bytes, tiff) == 0x4d and list_at(bytes, tiff + 1) == 0x4d
			if (!little and !big) or read_u16_ordered(bytes, tiff + 2, little) != 42 {
				Err(
					InvalidExif({
						resource: resource,
					}),
				)
			} else {
				offset = read_u32_ordered(bytes, tiff + 4, little).to_u64()
				if offset > end - tiff or end - (tiff + offset) < 2 {
					Err(
						InvalidExif({
							resource: resource,
						}),
					)
				} else {
					ifd = tiff + offset
					count = read_u16_ordered(bytes, ifd, little).to_u64()
					table_bytes = match U64.times_try(count, 12) {
						Err(Overflow) => 0xffffffffffffffff
						Ok(value) => value
					}
					if table_bytes > end - (ifd + 2) {
						Err(
							InvalidExif({
								resource: resource,
							}),
						)
					} else {
						var $index = 0
						var $found = NoExif
						while $index < count {
							entry = ifd + 2 + $index * 12
							tag = read_u16_ordered(bytes, entry, little)
							if tag == 0x0112 {
								type = read_u16_ordered(bytes, entry + 2, little)
								items = read_u32_ordered(bytes, entry + 4, little)
								value = read_u16_ordered(bytes, entry + 8, little)
								if type != 3 or items != 1 or value < 1 or value > 8 or $found != NoExif {
									return Err(InvalidExif({ resource: resource }))
								} else {
									$found = Exif(orientation_from_u16(value))
								}
							}
							$index = $index + 1
						}
						Ok($found)
					}
				}
			}
		}
	}

	orientation_from_u16 : U16 -> Orientation
	orientation_from_u16 = |value| match value {
		1 => TopLeft
		2 => TopRight
		3 => BottomRight
		4 => BottomLeft
		5 => LeftTop
		6 => RightTop
		7 => RightBottom
		_ => LeftBottom
	}

	read_u16_be : List(U8), U64 -> U16
	read_u16_be = |bytes, index| list_at(bytes, index).to_u16().shl_wrap(8).bitwise_or(list_at(bytes, index + 1).to_u16())

	read_u16_ordered : List(U8), U64, Bool -> U16
	read_u16_ordered = |bytes, index, little| if (little) list_at(bytes, index).to_u16().bitwise_or(list_at(bytes, index + 1).to_u16().shl_wrap(8)) else read_u16_be(bytes, index)

	read_u32_ordered : List(U8), U64, Bool -> U32
	read_u32_ordered = |bytes, index, little| if (little) list_at(bytes, index).to_u32()
		.bitwise_or(list_at(bytes, index + 1).to_u32().shl_wrap(8))
		.bitwise_or(list_at(bytes, index + 2).to_u32().shl_wrap(16))
		.bitwise_or(list_at(bytes, index + 3).to_u32().shl_wrap(24)) else list_at(bytes, index).to_u32().shl_wrap(24)
		.bitwise_or(list_at(bytes, index + 1).to_u32().shl_wrap(16))
		.bitwise_or(list_at(bytes, index + 2).to_u32().shl_wrap(8))
		.bitwise_or(list_at(bytes, index + 3).to_u32())

	list_at : List(a), U64 -> a
	list_at = |items, index| match items.get(index) {
		Ok(value) => value
		Err(OutOfBounds) => {
			crash "validated image index escaped"
		}
	}

	# -- The walk as terms, one stage per guard -------------------------------

	## Lines 440 to 458: the guard on the TIFF header, and the bytes read once
	## it passes. The furthest of them is `tiff + 7`, the last byte of the
	## directory offset.
	header = |start, length, len| {
		tiff = start + 6
		end = start + length
		{ tiff, end, passes: (end - tiff).gte(8), reads: (tiff + 7).lt(len) }
	}

	## Lines 459 to 467: the guard on the directory offset, and the two bytes
	## of the entry count.
	directory = |tiff, end, len, offset| {
		ifd = tiff + offset
		{ ifd, passes: Solve.any([offset.gt(end - tiff), (end - (tiff + offset)).lt(2)]).not(), reads: (ifd + 1).lt(len) }
	}

	## Lines 468 to 471 and the product on line 482: the size of the entry
	## table, and how far into it turn `index` of the loop starts.
	products = |count, index| {
		table_bytes: Solve.if_else(count.times_overflows(12), 0xffff_ffff_ffff_ffff, count * 12),
		step: index * 12,
	}

	## Lines 472 to 487: the guard on the entry table, and one turn of the
	## loop. The furthest byte a turn can read is `entry + 9`.
	entries = |ifd, end, len, table_bytes, step| {
		entry = ifd + 2 + step
		{ passes: table_bytes.gt(end - (ifd + 2)).not(), reads: (entry + 9).lt(len) }
	}

	Walk(n) : { start : n, length : n, len : n, offset : n, count : n, index : n }

	## The stages joined the way the function joins them: `reaches_loop` when
	## all three guards pass, and `is_safe` when nothing on the way overflows
	## and every byte read is inside the list.
	walk : Walk(Solve.Uint) -> { reaches_loop : Solve.Claim, is_safe : Solve.Claim }
	walk = |{ start, length, len, offset, count, index }| {
		h = header(start, length, len)
		d = directory(h.tiff, h.end, len, offset)
		p = products(count, index)
		e = entries(d.ifd, h.end, len, p.table_bytes, p.step)
		{
			reaches_loop: Solve.all([h.passes, d.passes, e.passes]),
			is_safe: h.passes.implies(Solve.all([h.reads, d.passes.implies(Solve.all([d.reads, e.passes.implies(index.lt(count).implies(e.reads))]))])),
		}
	}

	# -- What each stage needs and what it leaves behind ----------------------

	## The segment `start .. start + length` lies inside the bytes. Every
	## walker in the file needs this of its caller.
	segment_lies_inside : Solve.Uint, Solve.Uint, Solve.Uint -> Solve.Claim
	segment_lies_inside = |start, length, len| Solve.all([start.plus_overflows(length).not(), (start + length).lte(len)])

	## What the header stage leaves for the directory stage.
	after_header : Solve.Uint, Solve.Uint, Solve.Uint -> Solve.Claim
	after_header = |tiff, end, len| Solve.all([tiff.lte(end), end.lte(len)])

	## What the directory stage leaves for the entry stage.
	after_directory : Solve.Uint, Solve.Uint, Solve.Uint -> Solve.Claim
	after_directory = |ifd, end, len| Solve.all([ifd.plus_overflows(2).not(), (ifd + 2).lte(end), end.lte(len)])

	## What the two products leave for the entry stage: the twelve bytes of a
	## turn end inside the table.
	turn_ends_inside_table : Solve.Uint, Solve.Uint -> Solve.Claim
	turn_ends_inside_table = |table_bytes, step| Solve.all([step.plus_overflows(12).not(), (step + 12).lte(table_bytes)])

	## The largest entry table: 65,535 entries of twelve bytes.
	largest_table : U64
	largest_table = 786_420

	# -- The questions ----------------------------------------------------------

	Segment(n) : { start : n, length : n, len : n }

	segments : Solve.Vars(Segment(Solve.Uint))
	segments = { start: Solve.u64, length: Solve.u64, len: Solve.u64 }.Solve

	SegmentVerdict : Try([Proved, Refuted(Segment(Solve.Uint)), Crashes(Segment(Solve.Uint))], Solve.Problem)

	## Stage one. Given what the caller is assumed to have checked, does the
	## header stage run without overflow, read inside the list, and leave
	## `after_header` behind?
	header_is_safe : (Segment(Solve.Uint) -> Solve.Claim) -> SegmentVerdict
	header_is_safe = |assumed| Solve.prove(
		segments,
		|v| assumed(v).implies(
			{
				h = header(v.start, v.length, v.len)
				Solve.all([h.passes.implies(h.reads), after_header(h.tiff, h.end, v.len)])
			},
		),
	)

	## Under `segment_lies_inside`, the first three lines of the walker crash
	## exactly when `length < 6`.
	header_crashes_exactly_below_six : {} -> SegmentVerdict
	header_crashes_exactly_below_six = |{}| Solve.prove(
		segments,
		|v| segment_lies_inside(v.start, v.length, v.len).implies(
			Solve.any([v.start.plus_overflows(6), (v.start + v.length).minus_overflows(v.start + 6)]).iff(v.length.lt(6)),
		),
	)

	Directory : { tiff : Solve.Uint, end : Solve.Uint, len : Solve.Uint, offset : Solve.Uint }

	## Stage two, from any state `after_header` allows and any directory
	## offset a 32-bit field can hold.
	directory_is_safe : {} -> Try([Proved, Refuted(Directory), Crashes(Directory)], Solve.Problem)
	directory_is_safe = |{}| Solve.prove(
		{ tiff: Solve.u64, end: Solve.u64, len: Solve.u64, offset: Solve.u64_in(0, 0xffff_ffff) }.Solve,
		|v| after_header(v.tiff, v.end, v.len).implies(
			{
				d = directory(v.tiff, v.end, v.len, v.offset)
				d.passes.implies(Solve.all([d.reads, after_directory(d.ifd, v.end, v.len)]))
			},
		),
	)

	Turn : { count : Solve.Uint, index : Solve.Uint }

	## Stage three, the products: for any entry count a 16-bit field can hold
	## the table is no larger than `largest_table`, and any turn of the loop
	## ends inside it. `index` is given the range of `count` because the loop
	## only runs while `index < count`.
	products_are_safe : {} -> Try([Proved, Refuted(Turn), Crashes(Turn)], Solve.Problem)
	products_are_safe = |{}| Solve.prove(
		{ count: Solve.u64_in(0, 0xffff), index: Solve.u64_in(0, 0xffff) }.Solve,
		|v| {
			p = products(v.count, v.index)
			Solve.all([p.table_bytes.lte(Solve.num(largest_table)), v.index.lt(v.count).implies(turn_ends_inside_table(p.table_bytes, p.step))])
		},
	)

	Entries : { ifd : Solve.Uint, end : Solve.Uint, len : Solve.Uint, table_bytes : Solve.Uint, step : Solve.Uint }

	## Stage three, the reads: from any state `after_directory` allows, the
	## guard runs without overflow for any table up to `largest_table`, and a
	## turn that ends inside the table reads inside the list. `table_bytes`
	## and `step` have the range `products_are_safe` puts them in.
	entries_are_safe : {} -> Try([Proved, Refuted(Entries), Crashes(Entries)], Solve.Problem)
	entries_are_safe = |{}| Solve.prove(
		{ ifd: Solve.u64, end: Solve.u64, len: Solve.u64, table_bytes: Solve.u64_in(0, largest_table), step: Solve.u64_in(0, largest_table) }.Solve,
		|v| after_directory(v.ifd, v.end, v.len).implies(
			{
				e = entries(v.ifd, v.end, v.len, v.table_bytes, v.step)
				e.passes.implies(turn_ends_inside_table(v.table_bytes, v.step).implies(e.reads))
			},
		),
	)

	# -- The caller -------------------------------------------------------------

	## Lines 178 to 187 of `inspect_jpeg`, which every segment goes through
	## before any walker sees it. `code_index` is where the marker byte is and
	## `segment_length` is the two bytes after it.
	segment = |code_index, segment_length, len| {
		data_start = code_index + 3
		{
			data_start,
			data_length: segment_length - 2,
			# 178: `else if $code_index + 2 >= bytes.len() { return Err(..) }`
			has_length: (code_index + 2).gte(len).not(),
			# 181: `read_u16_be(bytes, $code_index + 1)`
			length_reads: (code_index + 1 + 1).lt(len),
			# 183: `if segment_length < 2 or segment_length - 2 > bytes.len() - data_start { return Err(..) }`
			fits: Solve.any([segment_length.lt(2), (segment_length - 2).gt(len - data_start)]).not(),
		}
	}

	Marker : { code_index : Solve.Uint, segment_length : Solve.Uint, len : Solve.Uint }

	## Do the caller's guards hand every walker a segment inside the bytes?
	## Line 160 has already rejected `code_index >= bytes.len()`.
	caller_hands_over_a_segment : Solve.Vars(Solve.Uint) -> Try([Proved, Refuted(Marker), Crashes(Marker)], Solve.Problem)
	caller_hands_over_a_segment = |list_lengths| Solve.prove(
		{ code_index: Solve.u64, segment_length: Solve.u64_in(0, 0xffff), len: list_lengths }.Solve,
		|v| v.code_index.lt(v.len).implies(
			{
				s = segment(v.code_index, v.segment_length, v.len)
				s.has_length.implies(
					Solve.all([
						s.length_reads,
						s.fits.implies(segment_lies_inside(s.data_start, s.data_length, v.len)),
					]),
				)
			},
		),
	)

	# -- The walker next door ---------------------------------------------------

	## Lines 299 to 304 of `inspect_frame`: it tests `length < 6` itself and
	## then reads `start` to `start + 5`.
	frame_is_safe : {} -> SegmentVerdict
	frame_is_safe = |{}| Solve.prove(
		segments,
		|v| segment_lies_inside(v.start, v.length, v.len).implies(v.length.lt(6).not().implies((v.start + 5).lt(v.len))),
	)

	# -- Tying the terms to the copy --------------------------------------------

	Shape : { start : U64, length : U64, offset : U32, count : U16, little : Bool }

	## Exactly `start + length` bytes: zeros, with a TIFF header six bytes
	## after `start` naming `offset`, and an entry count at that offset. What
	## does not fit is left out. The list ends where the segment ends, so a
	## read past the segment crashes the copy.
	segment_bytes : Shape -> List(U8)
	segment_bytes = |{ start, length, offset, count, little }| {
		tiff = start + 6
		low = count.to_u8_wrap()
		high = count.shr_wrap(8).to_u8_wrap()
		o0 = offset.to_u8_wrap()
		o1 = offset.shr_wrap(8).to_u8_wrap()
		o2 = offset.shr_wrap(16).to_u8_wrap()
		o3 = offset.shr_wrap(24).to_u8_wrap()
		blank = List.repeat(0, start + length)
		with_count = write(
			blank,
			tiff + offset.to_u64(),
			if little {
				[low, high]
			} else {
				[high, low]
			},
		)
		write(
			with_count,
			tiff,
			if little {
				[0x49, 0x49, 42, 0, o0, o1, o2, o3]
			} else {
				[0x4d, 0x4d, 0, 42, o3, o2, o1, o0]
			},
		)
	}

	## `bytes` with as much of `values` written from `at` as fits.
	write : List(U8), U64, List(U8) -> List(U8)
	write = |bytes, at, values| {
		var $bytes = bytes
		var $next = at
		for value in values {
			$bytes = $bytes.set($next, value) ?? $bytes
			$next = $next + 1
		}
		$bytes
	}

	## The walk through `segment_bytes(shape)` as terms. `count` is what the
	## walker would find at the directory offset, which is not `shape.count`
	## when the offset points back into the header.
	as_walk : Shape, List(U8), U64 -> Walk(Solve.Uint)
	as_walk = |shape, bytes, index| {
		ifd = shape.start + 6 + shape.offset.to_u64()
		count = if ifd + 1 < bytes.len() {
			read_u16_ordered(bytes, ifd, shape.little).to_u64()
		} else {
			0
		}
		{
			start: Solve.Uint.from_u64(shape.start),
			length: Solve.Uint.from_u64(shape.length),
			len: Solve.Uint.from_u64(bytes.len()),
			offset: Solve.Uint.from_u64(shape.offset.to_u64()),
			count: Solve.Uint.from_u64(count),
			index: Solve.Uint.from_u64(index),
		}
	}

	## Segments around every boundary in the three guards, in both byte
	## orders. Every length is at least six, since below that the copy crashes.
	boundary_shapes : {} -> List(Shape)
	boundary_shapes = |{}| {
		var $shapes = []
		for start in [0, 20] {
			for length in [6, 13, 14, 15, 16, 17, 26, 27, 28, 38, 40, 100] {
				for offset in [0, 1, 6, 7, 8, 9, 10, 20, 21, 22, 30, 86, 92, 93, 94, 0xffff_ffff] {
					for count in [0, 1, 2, 3, 7, 0xffff] {
						for little in [Bool.True, Bool.False] {
							$shapes = $shapes.append({ start, length, offset, count, little })
						}
					}
				}
			}
		}
		$shapes
	}
}

## Without `length >= 6` the empty segment crashes the walker on line 442.
expect ExifWalker.header_is_safe(|v| ExifWalker.segment_lies_inside(v.start, v.length, v.len)) == Ok(Crashes({ start: 0, length: 0, len: 0 }))

## `length >= 6` alone is not enough either: nothing stops `start + length`
## overflowing.
expect ExifWalker.header_is_safe(|v| v.length.gte(6)) == Ok(Crashes({ start: 481_036_337_147, length: 18_446_743_962_040_401_921, len: 0 }))

# The copy runs: a little-endian segment with one orientation entry.
expect {
	blank = ExifWalker.segment_bytes({ start: 3, length: 28, offset: 8, count: 1, little: Bool.True })
	bytes = ExifWalker.write(blank, 3 + 6 + 8 + 2, [0x12, 0x01, 3, 0, 1, 0, 0, 0, 6, 0])
	ExifWalker.inspect_exif_orientation(bytes, 3, 28, 0) == Ok(Exif(RightTop))
}

# Term against copy: the copy returns `Ok(NoExif)` exactly when the term says
# all three guards pass.
expect ExifWalker.boundary_shapes({}).all(
	|shape| {
		bytes = ExifWalker.segment_bytes(shape)
		real = ExifWalker.inspect_exif_orientation(bytes, shape.start, shape.length, 0)
		ExifWalker.walk(ExifWalker.as_walk(shape, bytes, 0)).reaches_loop.eval() == Ok(real == Ok(NoExif))
	},
)

# And the term calls every one of those walks safe, on the first, second and
# last turns of the loop.
expect ExifWalker.boundary_shapes({}).all(
	|shape| {
		bytes = ExifWalker.segment_bytes(shape)
		[0, 1, 0xfffe].all(|index| ExifWalker.walk(ExifWalker.as_walk(shape, bytes, index)).is_safe.eval() == Ok(Bool.True))
	},
)

# The grid has both kinds: 490 of its 4,608 segments reach the loop.
expect {
	shapes = ExifWalker.boundary_shapes({})
	reaching = shapes.count_if(
		|shape| {
			bytes = ExifWalker.segment_bytes(shape)
			ExifWalker.inspect_exif_orientation(bytes, shape.start, shape.length, 0) == Ok(NoExif)
		},
	)
	shapes.len() == 4608 and reaching == 490
}
