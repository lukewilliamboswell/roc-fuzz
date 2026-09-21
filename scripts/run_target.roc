#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0-rc1/3hT3SoHZ6qbEsa9qVFLUW3547U5LeoNd1KbpqLpz4r1i.tar.zst",
	ascii: "https://github.com/Hasnep/roc-ascii/releases/download/v0.5.0/5WxqRf15XVko4HxVq5dW8r84s95CxrtvzrjZYwbg9Z3H.tar.zst",
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.0/JXLM47L6CzrLXB5HBfqc27VnU6CD4jMm5Mk6dgbbovL.tar.zst",
	arg_path: "https://github.com/roc-lang/path/releases/download/4.0.0/7YfABZPwJAXtLBY2vm8FqMyGAtNxncCJ65HdNKHFGNnE.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.9.0/7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77.tar.zst",
	roc: "nightly-2026-09-18-1d982dc",
}

import cli.Env
import cli.OsStr
import cli.Path
import cli.Stderr
import weaver.Cli
import weaver.Opt
import weaver.Param
import src/CliValues
import src/BundleServer
import src/Files
import src/LibrarySource
import src/Project
import src/RocSource
import src/Script
import src/WeaverCli

main! = |raw_args| {
	cli_options = match WeaverCli.parse!(cli_parser, raw_args)? {
		Run(parsed) => parsed
		Exit => return Ok({})
	}
	source_path = Path.absolute!(cli_options.source_path)?
	Script.require_file!(source_path)?
	if Path.ext(source_path).map_ok(Path.display) != Ok("roc") {
		return Err(TargetMustBeRocSource(Path.display(source_path)))
	}
	stable = Script.roc_stable!()?
	nightly = Script.roc_nightly!()?
	run_target!(source_path, cli_options.libraries, runner_args(cli_options), stable, nightly)
}

runner_args = |options| {
	base_args : List(OsStr)
	base_args = ["run"]
	corpus_args = match options.corpus {
		Ok(value) => base_args.append(Path.to_os_str(value))
		Err(NoValue) => base_args
	}
	time_args = append_number(corpus_args, "time", options.time)
	run_args = append_number(time_args, "runs", options.runs)
	input_args = append_number(run_args, "max-input-size", options.max_input_size)
	memory_args = append_number(input_args, "memory-limit", options.memory_limit)
	timeout_args = append_number(memory_args, "timeout", options.timeout)
	seed_args = append_number(timeout_args, "seed", options.seed)
	if options.verbose seed_args.append("--print-final-stats") else seed_args
}

append_number = |args, name, value|
	match value {
		Ok(number) => args.append(OsStr.from_str("--${name}=${number.to_str()}"))
		Err(NoValue) => args
	}

run_target! = |source_path, library_source, args, stable, nightly| {
	target_name = Project.host_target!()?.name()
	Script.info!("PREPARE", "Building ${target_name} platform inputs from ${LibrarySource.to_str(library_source)} libraries")?
	stable.run!(["scripts/build_platform.roc", "--", "--target", OsStr.from_str(target_name), "--libraries", OsStr.from_str(LibrarySource.to_str(library_source))])?
	Env.with_temp_dir!(|temporary| run_in_workspace!(temporary, source_path, target_name, args, stable, nightly))
}

run_in_workspace! = |temporary, source_path, target_name, args, stable, nightly| {
	bundle_dir = Path.join(temporary, "bundle")
	stable.run!(["scripts/build_bundle.roc", "--", "--target", OsStr.from_str(target_name), "--output-dir", Path.to_os_str(bundle_dir)])?
	bundles = Files.direct_files!(bundle_dir)?.keep_if(|path| Script.ends_with(Path.display(path), ".tar.zst"))
	bundle = match bundles {
		[only] => only
		_ => return Err(ExpectedOneBundle(bundles.len()))
	}
	filename = Path.filename(bundle).map_ok(Path.display).map_err(|_| InvalidBundlePath(Path.display(bundle)))?
	BundleServer.with!(filename, Path.read_bytes!(bundle)?, |server| build_and_run!(temporary, source_path, server, args, nightly))
}

build_and_run! = |temporary, source_path, server, args, nightly| {
	parent = parent_path(source_path)?
	local_dir = Path.join(temporary, "app")
	Path.copy_dir!(parent, local_dir)?
	app_name = Path.filename(source_path).map_err(|_| TargetHasNoFilename(Path.display(source_path)))?
	local_app = Path.join(local_dir, Path.display(app_name))
	Path.write_utf8!(local_app, RocSource.replace_platform(Path.read_utf8!(local_app)?, server.url())?)?
	Path.create_all!(".test-cache/run")?
	executable : Path
	executable = ".test-cache/run/${Files.stem(Path.display(app_name))}"
	child = nightly.cmd(["build", "--fuzz", Path.to_os_str(local_app), OsStr.from_str("--output=${Path.display(executable)}")]).stdout(Capture).stderr(Capture).spawn!().map_err(|err| TargetBuildSpawnFailed(err))?
	output = server.serve_child!(child)?
	match output.status {
		Exited(0) => {}
		Exited(code) => {
			Stderr.write_bytes!(output.stderr_bytes)?
			return Err(TargetBuildExited(code))
		}
		Signaled(signal) => return Err(TargetBuildSignaled(signal))
	}
	Script.command(Path.to_os_str(executable)).run!(args)
}

parent_path = |path| {
	filename = Path.filename(path).map_ok(Path.display).map_err(|_| TargetHasNoParent(Path.display(path)))?
	bytes = Path.display(path).to_utf8()
	if bytes.len() <= filename.to_utf8().len() {
		return Err(TargetHasNoParent(Path.display(path)))
	}
	Ok(Path.utf8(Str.from_utf8_lossy(bytes.drop_last(filename.to_utf8().len() + 1))))
}

cli_parser = Cli.assert_valid(
	Cli.finish(
		{
			corpus: Opt.maybe({ short: "", long: "corpus", help: "Corpus directory.", type: "path", parser: CliValues.path }),
			libraries: Opt.single({ short: "", long: "libraries", help: "Use release or source native libraries. [default: release]", type: "library-source", default: Value(LibrarySource.default), parser: parse_library_source }),
			max_input_size: Opt.maybe_u64({ short: "", long: "max-input-size", help: "Maximum generated input size." }),
			memory_limit: Opt.maybe_u64({ short: "", long: "memory-limit", help: "Memory limit in MiB." }),
			runs: Opt.maybe_u64({ short: "", long: "runs", help: "Number of fuzz runs." }),
			seed: Opt.maybe_u64({ short: "", long: "seed", help: "Deterministic libFuzzer seed." }),
			time: Opt.maybe_u64({ short: "", long: "time", help: "Maximum fuzzing time in seconds." }),
			timeout: Opt.maybe_u64({ short: "", long: "timeout", help: "Per-input timeout in seconds." }),
			verbose: Opt.flag({ short: "v", long: "verbose", help: "Print final libFuzzer statistics." }),
			source_path: Param.single({ name: "app", help: "Roc app exposing a fuzz target.", type: "path", default: NoDefault, parser: CliValues.path }),
		}.Cli,
		{
			name: "run-target",
			version: "development",
			authors: [],
			description: "Rebuild the host platform and run one fuzz target against a fresh local bundle.",
			text_style: Plain,
		},
	),
)

parse_library_source : _ -> Try(LibrarySource.LibrarySource, [InvalidNumStr, InvalidValue(Str), InvalidUtf8])
parse_library_source = |argument| CliValues.parse(argument, LibrarySource.parse, "expected release or source")
