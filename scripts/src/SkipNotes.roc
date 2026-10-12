import cli.Path
import Script

## Why part of a case is switched off. `tests/targets.json` turns the seed
## replay or the fuzz run of a case off with `skip_seed` or `skip_fuzz`, and
## its `skips` list says why and names the issue that will turn it back on.
SkipNotes := [].{
	Note : { name : Str, operation : Str, reason : Str, issue : Str }
	Switch : { name : Str, skip_seed : Bool, skip_fuzz : Bool }

	## The notes a suite records. An examples archive published before notes
	## existed has none.
	load! = |path| {
		parsed : Try({ skips : List(Note) }, _)
		parsed = Json.parse(Path.read_utf8!(path)?)
		match parsed {
			Ok(found) => Ok(found.skips)
			Err(_) => Ok([])
		}
	}

	describe = |notes, name, operation|
		match notes.keep_if(|note| note.name == name and note.operation == operation) {
			[note, ..] => "${note.reason} (${note.issue})"
			_ => "no reason recorded"
		}

	## Every skip has exactly one note with a reason and an issue link, and
	## every note belongs to a skip. A note left behind after a case is
	## switched back on fails, so the list cannot go stale.
	validate : List(Switch), List(Note) -> Try({}, _)
	validate = |cases, notes| {
		for note in notes {
			if (note.operation != "seed" and note.operation != "fuzz") or note.reason.is_empty() or !Script.starts_with(note.issue, "https://") {
				return Err(InvalidSkipNote(note.name))
			}
			if !cases.any(|item| item.name == note.name and switched_off(item, note.operation)) {
				return Err(SkipNoteWithoutSkip(note.name, note.operation))
			}
		}
		for item in cases {
			for operation in ["seed", "fuzz"] {
				if switched_off(item, operation) and notes.keep_if(|note| note.name == item.name and note.operation == operation).len() != 1 {
					return Err(SkipWithoutNote(item.name, operation))
				}
			}
		}
		Ok({})
	}
}

switched_off = |item, operation| if operation == "seed" item.skip_seed else item.skip_fuzz

running : SkipNotes.Switch
running = { name: "running", skip_seed: Bool.False, skip_fuzz: Bool.False }

hanging : SkipNotes.Switch
hanging = { name: "hanging", skip_seed: Bool.False, skip_fuzz: Bool.True }

noted : SkipNotes.Note
noted = { name: "hanging", operation: "fuzz", reason: "The parser does not terminate on some inputs.", issue: "https://github.com/owner/repo/issues/1" }

expect SkipNotes.validate([running], []) == Ok({})
expect SkipNotes.validate([running, hanging], [noted]) == Ok({})
expect SkipNotes.validate([running, hanging], []) == Err(SkipWithoutNote("hanging", "fuzz"))
expect SkipNotes.validate([running], [noted]) == Err(SkipNoteWithoutSkip("hanging", "fuzz"))
expect SkipNotes.validate([hanging], [{ ..noted, issue: "later" }]) == Err(InvalidSkipNote("hanging"))
expect SkipNotes.validate([hanging], [{ ..noted, operation: "seed" }]) == Err(SkipNoteWithoutSkip("hanging", "seed"))
expect SkipNotes.describe([noted], "hanging", "fuzz") == "The parser does not terminate on some inputs. (https://github.com/owner/repo/issues/1)"
expect SkipNotes.describe([], "hanging", "fuzz") == "no reason recorded"
