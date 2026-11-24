## The table-range check of roc-pdf's font directory walk, before and after
## the one-line fix in roc-pdf commit e1c3220, "Fix table-range underflow in
## the font directory check".
##
## `inspect_font` in roc-pdf `package/KernelFont.roc` reads `offset` and
## `length` from each 16-byte table record and rejects the font unless the
## table lies inside the font's bytes. That is line 190 as of roc-pdf 0d4f3ee
## and was line 164 before the fix. Everything after it indexes `bytes` with
## those two numbers through accessors that crash on a bad index.
##
## ## The claim
##
## If the guard does not reject a record, then `offset + length <= bytes.len()`,
## and neither the guard nor that sum overflows.
##
## ## What is established
##
## - Today's guard: `Proved` for every `offset` and `length` a 32-bit field
##   can hold, every directory length a font can have, and every 64-bit
##   `bytes.len()` (`accepted_tables_lie_inside`), and for any four `U64`s
##   with nothing assumed (`accepted_tables_lie_inside_always`). Those two
##   proofs take about half a minute and three minutes on the default
##   backend, so the tests here do not ask them; ask them under
##   `--opt=speed`. The tests here confirm the bug and tie terms to copies.
## - The guard before the fix: `Crashes`, with a record at offset 60 in a
##   28-byte font. On a compiler whose `-` wraps, which is how the commit
##   message describes the bug, the same guard is `Refuted`: it accepts a
##   table that starts past the end.
##
## ## What is not established
##
## - That the terms are the code. `rejects_after` and `rejects_before` are
##   copies of one line each, and the two `_term` functions restate them by
##   hand. The tests at the bottom run copy and term on 900 boundary records
##   and require the same answer. Nothing stops the copies drifting from
##   roc-pdf.
## - Anything about the loop around the guard or the code after it. The claim
##   is about one `if`. That later reads stay inside an accepted table is not
##   shown here.
## - `Proved` rests on the solver finding nothing. `Crashes` and `Refuted` do
##   not: their values were run through the plain evaluator, and the crash was
##   reproduced in plain Roc as described under `rejects_before`.
import fuzz.Solve

FontDirectory := [].{

	## What `inspect_font` holds when it reaches the guard. `len` is
	## `bytes.len()`.
	Record(n) : { offset : n, length : n, directory_length : n, len : n }

	# -- The real code, copied ----------------------------------------------

	## Line 190 of `package/KernelFont.roc` today, with `bytes.len()` passed
	## in. `True` means the font is rejected with `InvalidTableRange`.
	rejects_after : Record(U64) -> Bool
	rejects_after = |{ offset, length, directory_length, len }|
		offset % 4 != 0 or offset < directory_length or offset > len or length > len - offset

	## Line 164 before e1c3220.
	##
	## `rejects_before({ offset: 60, length: 8138, directory_length: 28, len: 28 })`
	## stops with "Integer subtraction overflowed" under Roc 0.1.0_RC1, on the
	## dev backend and in the interpreter. An `expect` cannot assert a crash,
	## so no test here makes that call. The same crash comes out of the real
	## function: today's `KernelFont.inspect` with this one line put back,
	## given a 28-byte font whose only table record says offset 60 and length
	## 8138. Today's line answers `InvalidTableRange({ length: 8138, offset: 60 })`.
	rejects_before : Record(U64) -> Bool
	rejects_before = |{ offset, length, directory_length, len }|
		offset % 4 != 0 or offset < directory_length or length > len - offset

	# -- The same guards as terms ---------------------------------------------

	rejects_after_term : Record(Solve.Uint) -> Solve.Claim
	rejects_after_term = |{ offset, length, directory_length, len }|
		Solve.any([(offset % 4).neq(0), offset.lt(directory_length), offset.gt(len), length.gt(len - offset)])

	rejects_before_term : Record(Solve.Uint) -> Solve.Claim
	rejects_before_term = |{ offset, length, directory_length, len }|
		Solve.any([(offset % 4).neq(0), offset.lt(directory_length), length.gt(len - offset)])

	## The guard before the fix on a compiler whose `-` wraps around.
	rejects_before_wrapping_term : Record(Solve.Uint) -> Solve.Claim
	rejects_before_wrapping_term = |{ offset, length, directory_length, len }|
		Solve.any([(offset % 4).neq(0), offset.lt(directory_length), length.gt(len.minus_wrap(offset))])

	# -- The claim ------------------------------------------------------------

	## Every record the real function can be looking at when it reaches the
	## guard. `offset` and `length` come from `read_u32(..).to_u64()`. The
	## directory holds 1 to 65,535 records of 16 bytes after a 12-byte header.
	reachable : Solve.Vars(Record(Solve.Uint))
	reachable = {
		offset: Solve.u64_in(0, 0xffff_ffff),
		length: Solve.u64_in(0, 0xffff_ffff),
		directory_length: Solve.u64_in(28, 1_048_572),
		len: Solve.u64,
	}.Solve

	## What lines 166 to 176 have checked by then: the directory length is
	## `12 + table_count * 16` and the directory itself fits in the bytes.
	## Without this the solver may answer with a state the function never
	## reaches.
	reached : Record(Solve.Uint) -> Solve.Claim
	reached = |v| Solve.all([((v.directory_length - 12) % 16).eq(0), v.directory_length.lte(v.len)])

	## The table lies inside the bytes. The sum is Roc's `+`, so the claim
	## crashes, and is not proved, if the end of the table does not fit a
	## `U64`.
	lies_inside : Record(Solve.Uint) -> Solve.Claim
	lies_inside = |v| Solve.all([v.offset.lte(v.len), (v.offset + v.length).lte(v.len)])

	Verdict : Try([Proved, Refuted(Record(Solve.Uint)), Crashes(Record(Solve.Uint))], Solve.Problem)

	## Does every reachable record the guard lets through lie inside the bytes?
	accepted_tables_lie_inside : (Record(Solve.Uint) -> Solve.Claim) -> Verdict
	accepted_tables_lie_inside = |rejects| Solve.prove(
		reachable,
		|v| reached(v).implies(rejects(v).not().implies(lies_inside(v))),
	)

	## The same question with nothing assumed: any four `U64`s.
	accepted_tables_lie_inside_always : (Record(Solve.Uint) -> Solve.Claim) -> Verdict
	accepted_tables_lie_inside_always = |rejects| Solve.prove(
		{ offset: Solve.u64, length: Solve.u64, directory_length: Solve.u64, len: Solve.u64 }.Solve,
		|v| rejects(v).not().implies(lies_inside(v)),
	)

	# -- Tying the terms to the copies ----------------------------------------

	as_terms : Record(U64) -> Record(Solve.Uint)
	as_terms = |{ offset, length, directory_length, len }| {
		offset: Solve.Uint.from_u64(offset),
		length: Solve.Uint.from_u64(length),
		directory_length: Solve.Uint.from_u64(directory_length),
		len: Solve.Uint.from_u64(len),
	}

	## 900 records around every boundary in the guards: multiples of four and
	## their neighbours, the directory length, the end of the bytes, the top
	## of a 32-bit field and the top of a `U64`.
	boundary_records : {} -> List(Record(U64))
	boundary_records = |{}| {
		var $records = []
		for offset in [0, 3, 4, 27, 28, 32, 60, 64, 0xffff_fffc, 0xffff_ffff] {
			for length in [0, 1, 4, 8138, 0xffff_ffff] {
				for directory_length in [28, 44] {
					for len in [28, 31, 32, 60, 64, 8198, 0xffff_ffff, 0x1_ffff_fffb, U64.highest] {
						$records = $records.append({ offset, length, directory_length, len })
					}
				}
			}
		}
		$records
	}
}

## Before the fix the guard itself crashes: a one-table font of 28 bytes whose
## record says the table starts at byte 60.
expect FontDirectory.accepted_tables_lie_inside(FontDirectory.rejects_before_term) == Ok(Crashes({ offset: 60, length: 8138, directory_length: 28, len: 28 }))

## With a wrapping `-` the guard does not crash. It accepts a table that
## starts past the end of the bytes.
expect FontDirectory.accepted_tables_lie_inside(FontDirectory.rejects_before_wrapping_term) == Ok(Refuted({ offset: 1_560_106_676, length: 2_853_175_296, directory_length: 28, len: 234_707_764 }))

## The 28-byte font above is accepted by the wrapping guard too, and rejected
## by today's line. Plain Roc and the evaluator, no solver.
expect {
	font = { offset: 60, length: 8138, directory_length: 28, len: 28 }
	wrapped_bound = U64.minus_wrap(font.len, font.offset)
	wrapped_bound == 18_446_744_073_709_551_584
		and FontDirectory.rejects_before_wrapping_term(FontDirectory.as_terms(font)).eval() == Ok(Bool.False)
		and FontDirectory.rejects_before_term(FontDirectory.as_terms(font)).eval() == Err(Overflow)
		and FontDirectory.rejects_after(font)
}

## Term against copy, after the fix: the same answer on every boundary record,
## and the term never overflows where the copy does not crash.
expect FontDirectory.boundary_records({}).all(|record|
	FontDirectory.rejects_after_term(FontDirectory.as_terms(record)).eval() == Ok(FontDirectory.rejects_after(record)))

## Term against copy, before the fix. Where the term gives an answer the copy
## gives the same one. Where the term overflows the copy is not called, since
## it would crash the test: those are the records that start past the end of
## the bytes and pass the first two checks.
expect FontDirectory.boundary_records({}).all(
	|record|
		match FontDirectory.rejects_before_term(FontDirectory.as_terms(record)).eval() {
			Ok(answer) => answer == FontDirectory.rejects_before(record)
			Err(Overflow) => record.offset > record.len and record.offset % 4 == 0 and record.offset >= record.directory_length
			Err(_) => Bool.False
		},
)

## The grid is not all on one side: it has accepted records, rejected records
## and records that crash the old guard.
expect {
	records = FontDirectory.boundary_records({})
	accepted = records.count_if(|record| !FontDirectory.rejects_after(record))
	crashing = records.count_if(|record| FontDirectory.rejects_before_term(FontDirectory.as_terms(record)).eval() == Err(Overflow))
	records.len() == 900 and accepted > 0 and accepted < 900 and crashing > 0
}
