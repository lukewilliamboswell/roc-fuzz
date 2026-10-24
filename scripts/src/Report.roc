import cli.Cmd
import cli.Env
import ansi.ANSI

## How a harness reports a run: one line per step as it finishes, with its
## position, result and time, then a summary that stands on its own. Every
## duration is in milliseconds with digit separators, aligned to the right.
## Colour is an aid, never the only signal, and is off unless standard output
## is a terminal and `NO_COLOR` is unset.
Report := [].{
	Outcome : [Pass, Fail(Str), Skip(Str)]

	Step : { stage : Str, name : Str, outcome : Outcome, millis : U64 }

	## Whether to colour the output.
	color! = || {
		disabled = match Env.var_str!("NO_COLOR") {
			Ok(value) => !value.is_empty()
			Err(_) => Bool.False
		}
		if disabled {
			Bool.False
		} else {
			match Cmd.new("test").args(["-t", "1"]).inherit_stdio().run!() {
				Ok(output) => output.status == Exited(0)
				Err(_) => Bool.False
			}
		}
	}

	## A duration such as `1_204ms`.
	millis = |value| "${group(value)}ms"

	## The line printed when a step finishes.
	line : U64, U64, Step, Bool -> Str
	line = |position, total, step, colored| {
		width = total.to_str().to_utf8().len()
		label = "${step.stage} ${step.name} "
		dots = Str.repeat(".", if (label.to_utf8().len() < name_column) name_column - label.to_utf8().len() else 3)
		head = " [${pad_left(position.to_str(), width)}/${total.to_str()}] ${label}${dots}"
		match step.outcome {
			Pass => "${head} ${paint("PASS", Green, colored)} ${pad_left(Report.millis(step.millis), time_column)}"
			Fail(_) => "${head} ${paint("FAIL", Red, colored)} ${pad_left(Report.millis(step.millis), time_column)}"
			Skip(note) => "${head} ${paint("SKIP", Yellow, colored)} ${Str.repeat(" ", time_column)}  ${note}"
		}
	}

	## The summary printed after the last step: each failure with its detail,
	## each skip with its note, the counts and total time, and the slowest steps.
	summary : List(Step), U64, Bool -> List(Str)
	summary = |steps, total_millis, colored| {
		var $lines = []
		failed = steps.keep_if(|step| is_fail(step.outcome))
		skipped = steps.keep_if(|step| is_skip(step.outcome))
		if !failed.is_empty() {
			$lines = $lines.append("").append(paint("Failed", Red, colored))
			for step in failed {
				detail = match step.outcome {
					Fail(text) => text
					_ => ""
				}
				detail_lines = Str.split_on(detail, "\n")
				$lines = $lines.append("  ${step.stage} ${step.name}: ${detail_lines.first() ?? ""}")
				for text in detail_lines.drop_first(1) {
					$lines = $lines.append("    ${text}")
				}
			}
		}
		if !skipped.is_empty() {
			$lines = $lines.append("").append(paint("Skipped", Yellow, colored))
			for step in skipped {
				note = match step.outcome {
					Skip(text) => text
					_ => ""
				}
				$lines = $lines.append("  ${step.stage} ${step.name}: ${note}")
			}
		}
		passed = steps.len() - failed.len() - skipped.len()
		$lines = $lines.append("").append("Summary: ${passed.to_str()} passed, ${failed.len().to_str()} failed, ${skipped.len().to_str()} skipped in ${Report.millis(total_millis)}")
		slowest = steps.keep_if(|step| !is_skip(step.outcome)).sort_with(|a, b| if (a.millis > b.millis) Before else if (a.millis < b.millis) After else Same).take_first(3)
		if !slowest.is_empty() {
			$lines = $lines.append("Slowest: ${Str.join_with(slowest.map(|step| "${step.stage} ${step.name} ${Report.millis(step.millis)}"), ", ")}")
		}
		$lines
	}
}

name_column : U64
name_column = 48

time_column : U64
time_column = 9

group : U64 -> Str
group = |value|
	if value < 1000 {
		value.to_str()
	} else {
		rest = value % 1000
		padded = if (rest < 10) "00${rest.to_str()}" else if (rest < 100) "0${rest.to_str()}" else rest.to_str()
		"${group(value // 1000)}_${padded}"
	}

pad_left = |text, width| {
	length = text.to_utf8().len()
	if (length >= width) text else "${Str.repeat(" ", width - length)}${text}"
}

paint = |text, color, colored| if (colored) ANSI.color(text, { fg: Standard(color), bg: Default }) else text

is_fail = |outcome|
	match outcome {
		Fail(_) => Bool.True
		_ => Bool.False
	}

is_skip = |outcome|
	match outcome {
		Skip(_) => Bool.True
		_ => Bool.False
	}

expect Report.millis(0) == "0ms"
expect Report.millis(12) == "12ms"
expect Report.millis(1204) == "1_204ms"
expect Report.millis(10000) == "10_000ms"
expect Report.millis(1002003) == "1_002_003ms"

expect {
	text = Report.line(3, 20, { stage: "build", name: "listSort", outcome: Pass, millis: 1204 }, Bool.False)
	text == " [ 3/20] build listSort ................................. PASS   1_204ms"
}

expect {
	text = Report.line(12, 20, { stage: "seed", name: "dictOps", outcome: Skip("hangs (https://example.com/1)"), millis: 0 }, Bool.False)
	Str.contains(text, " SKIP ") and Str.contains(text, "hangs (https://example.com/1)") and Str.contains(text, "[12/20]")
}

expect {
	steps = [
		{ stage: "check", name: "a", outcome: Pass, millis: 12 },
		{ stage: "build", name: "a", outcome: Fail("`roc build` exited with code 1\nfirst line"), millis: 1204 },
		{ stage: "seed", name: "b", outcome: Skip("why (https://example.com/2)"), millis: 0 },
	]
	lines = Report.summary(steps, 10312, Bool.False)
	lines.contains("Summary: 1 passed, 1 failed, 1 skipped in 10_312ms")
		and lines.contains("  build a: `roc build` exited with code 1")
		and lines.contains("    first line")
		and lines.contains("  seed b: why (https://example.com/2)")
		and lines.contains("Slowest: build a 1_204ms, check a 12ms")
}
