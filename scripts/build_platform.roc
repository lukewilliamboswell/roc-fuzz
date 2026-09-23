#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0-rc1/3hT3SoHZ6qbEsa9qVFLUW3547U5LeoNd1KbpqLpz4r1i.tar.zst",
	ascii: "https://github.com/Hasnep/roc-ascii/releases/download/v0.5.0/5WxqRf15XVko4HxVq5dW8r84s95CxrtvzrjZYwbg9Z3H.tar.zst",
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.0/JXLM47L6CzrLXB5HBfqc27VnU6CD4jMm5Mk6dgbbovL.tar.zst",
	arg_path: "https://github.com/roc-lang/path/releases/download/4.0.0/7YfABZPwJAXtLBY2vm8FqMyGAtNxncCJ65HdNKHFGNnE.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.9.0/7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77.tar.zst",
	roc: "nightly-2026-09-18-1d982dc",
}

import cli.Cmd
import cli.Env
import cli.OsStr
import cli.Path
import weaver.Base exposing [InvalidValue]
import weaver.Cli
import weaver.Opt
import src/CliValues
import src/Files
import src/Identity
import src/Integrity
import src/LibrarySource
import src/PlatformInputs
import src/Project
import src/Script
import src/WeaverCli
import src/WorkspaceDeps

main! = |raw_args| {
	options = match WeaverCli.parse!(cli_parser, raw_args)? {
		Run(parsed) => parsed
		Exit => return Ok({})
	}
	root = Project.root!()?
	dependencies = WorkspaceDeps.current
	library_source = options.libraries
	mode = build_mode!(options.host_only, options.libraries_only, library_source)?
	specs = if options.target_specs.is_empty() [Project.host_target!()?.spec()] else options.target_specs
	zig = Script.command(Path.to_os_str(options.zig))
	ar = match options.ar {
		CustomAr(program) => Cmd.new(Path.to_os_str(program))
		DefaultAr => zig.cmd(["ar"])
	}
	libfuzzer_source = match options.libfuzzer_source {
		LocalSource(path) if library_source == Source => LocalSource(Path.absolute!(path)?)
		LocalSource(_) => return Script.fail!("--libfuzzer-source can only be used with --libraries source")
		PinnedSource => PinnedSource
	}
	glue = if options.regenerate_glue {
		RegenerateGlue(resolve_roc_source!(options)?)
	} else {
		KeepGlue
	}
	build = { ar, dependencies, glue, libfuzzer_source, library_source, mode, root, specs, zig }

	Script.info!("PLAN", build_summary(build))?
	prepare_glue!(build)?
	Env.with_temp_dir!(|work| build_targets!(build, work))?
	Script.pass!("platform inputs are ready")
}

build_summary = |build| {
	target_names = Str.join_with(build.specs.map(|spec| spec.target.name()), ", ")
	mode = match build.mode {
		Complete => "linker inputs and platform host"
		HostOnly => "platform host using existing libraries"
		LibrariesOnly => "linker inputs only"
	}
	"prepare ${mode} for ${target_names}"
}

cli_parser = Cli.assert_valid(
	Cli.finish(
		{
			ar: Cli.map(
				Opt.maybe({ short: "", long: "ar", help: "Use this archiver instead of `zig ar`.", type: "path", parser: CliValues.path }),
				|value| match value {
					Ok(program) => CustomAr(program)
					Err(NoValue) => DefaultAr
				},
			),
			host_only: Opt.flag({ short: "", long: "host-only", help: "Build a fresh host around already extracted candidate libraries." }),
			libraries: Opt.single({
				short: "",
				long: "libraries",
				help: "Use `release` libraries or build from `source`. [default: release]",
				type: "library-source",
				parser: parse_library_source_arg,
				default: Value(Release),
			}),
			libraries_only: Opt.flag({ short: "", long: "libraries-only", help: "Build only linker inputs for the independent release workflow." }),
			libfuzzer_source: Cli.map(
				Opt.maybe({ short: "", long: "libfuzzer-source", help: "Use a local libFuzzer source tree instead of the pinned source archive.", type: "path", parser: CliValues.path }),
				|value| match value {
					Ok(path) => LocalSource(path)
					Err(NoValue) => PinnedSource
				},
			),
			regenerate_glue: Opt.flag({ short: "", long: "regenerate-glue", help: "Regenerate the Zig natural-ABI bindings." }),
			roc_source: Cli.map(
				Opt.maybe({ short: "", long: "roc-source", help: "Roc source checkout used only with --regenerate-glue; otherwise ROC_SOURCE is used.", type: "path", parser: CliValues.path }),
				|value| match value {
					Ok(path) => RocSource(path)
					Err(NoValue) => EnvironmentRocSource
				},
			),
			target_specs: Opt.list({
				short: "",
				long: "target",
				help: "Target to generate; repeat to build more than one.",
				type: "target",
				parser: parse_target_spec_arg,
			}),
			zig: Opt.single({ short: "", long: "zig", help: "Zig executable. [default: zig]", type: "path", parser: CliValues.path, default: Value(Path.utf8("zig")) }),
		}.Cli,
		{
			name: "build-platform",
			version: "development",
			authors: [],
			description: "Prepare the linker inputs and host archive required by the roc-fuzz platform.",
			text_style: Plain,
		},
	),
)

parse_library_source_arg = |argument| CliValues.parse(argument, LibrarySource.parse, "expected release or source")

parse_target_spec_arg = |argument|
	match CliValues.parse(argument, Project.Target.parse, "unknown platform target") {
		Ok(target) => Ok(target.spec())
		Err(err) => Err(err)
	}

build_mode! = |host_only, libraries_only, library_source|
	if host_only and (libraries_only or library_source != Release) {
		Script.fail!("--host-only uses existing release libraries, so it cannot be combined with --libraries-only or --libraries source")
	} else if libraries_only and library_source != Source {
		Script.fail!("--libraries-only builds libraries from source; add --libraries source")
	} else if host_only {
		Ok(HostOnly)
	} else if libraries_only {
		Ok(LibrariesOnly)
	} else {
		Ok(Complete)
	}

resolve_roc_source! = |options| {
	path = match options.roc_source {
		RocSource(value) => value
		EnvironmentRocSource => match Env.var!("ROC_SOURCE") {
			Ok(value) => Path.from_os_str(value)
			Err(VarNotFound(_)) => return Script.fail!("--regenerate-glue needs a Roc checkout; pass --roc-source PATH or set ROC_SOURCE")
			Err(err) => return Err(EnvironmentInputError("ROC_SOURCE", err))
		}
	}
	Path.absolute!(path)
}

prepare_glue! = |build|
	match build.glue {
		KeepGlue => {
			generated = Path.join(Path.join(build.root, "src"), "roc_platform_abi.zig")
			if build.mode == LibrariesOnly or Path.is_file!(generated)? {
				Ok({})
			} else {
				Script.fail!("generated ABI glue is missing at ${Path.display(generated)}; restore the file or use --regenerate-glue with a Roc source checkout")
			}
		}
		RegenerateGlue(roc_source) => regenerate_glue!(build.root, roc_source, build.zig)
	}

regenerate_glue! = |root, roc_source, zig| {
	Script.info!("GLUE", "regenerating the Zig ABI bindings from the Roc compiler source")?
	roc = match Env.var!("ROC_NIGHTLY") {
		Ok(value) => Path.from_os_str(value)
		Err(VarNotFound(_)) => Path.join(Path.join(Path.join(roc_source, "zig-out"), "bin"), "roc")
		Err(err) => return Err(EnvironmentInputError("ROC_NIGHTLY", err))
	}
	glue = Path.join(Path.join(Path.join(Path.join(roc_source, "src"), "glue"), "src"), "ZigGlue.roc")
	if !Path.is_file!(roc)? {
		return Err(MissingGlueInput(roc))
	}
	if !Path.is_file!(glue)? {
		return Err(MissingGlueInput(glue))
	}
	Script.command(Path.to_os_str(roc)).run!(["glue", Path.to_os_str(glue), Path.to_os_str(Path.join(root, "src")), Path.to_os_str(Path.join(Path.join(root, "platform"), "main.roc"))])?
	zig.run!(["fmt", Path.to_os_str(Path.join(Path.join(root, "src"), "roc_platform_abi.zig"))])
}

build_targets! = |build, work| {
	libfuzzer = if build.library_source == Source {
		verify_zig_version!(build)?
		Available(resolve_libfuzzer_source!(build, work)?)
	} else {
		NotNeeded
	}
	for spec in build.specs {
		Script.info!("TARGET", "preparing ${Project.Target.name(spec.target)}")?
		prepare_target!(build, work, spec, libfuzzer)?
	}
	Ok({})
}

verify_zig_version! = |build| {
	installed = Script.trim(Str.from_utf8_lossy(build.zig.capture!(["version"], build.root, [])?))
	expected = build.dependencies.zig_version
	if installed == expected {
		Ok({})
	} else {
		Script.fail!("building libraries from source requires Zig ${expected}, but ${installed} is installed; pass the correct executable with --zig")
	}
}

prepare_target! = |build, work, spec, libfuzzer| {
	match (build.mode, libfuzzer) {
		(HostOnly, _) => {}
		(_, Available(source)) => {
			Script.info!("LIBRARIES", "building libFuzzer and the Zig runtime for ${Project.Target.name(spec.target)}")?
			build_libraries!(build.root, build.zig, build.ar, source, work, spec)?
		}
		(_, NotNeeded) => {
			Script.info!("LIBRARIES", "restoring the reviewed release libraries for ${Project.Target.name(spec.target)}")?
			Script.command("python3").run!(["scripts/link_input_artifacts.py", "install", "--target", OsStr.from_str(Project.Target.name(spec.target))])?
		}
	}
	if build.mode != LibrariesOnly {
		Script.info!("HOST", "building the Roc platform host for ${Project.Target.name(spec.target)}")?
		build_host!(build.root, build.zig, build.ar, work, spec)?
		manifest = PlatformInputs.write_manifest!(build.root, spec)?
		Script.pass!("recorded platform input checksums in ${Path.display(manifest)}")?
	}
	Ok({})
}

resolve_libfuzzer_source! = |build, work|
	match build.libfuzzer_source {
		LocalSource(path) => validate_libfuzzer_source!(path)
		PinnedSource => fetch_pinned_libfuzzer!(build.root, build.dependencies.libfuzzer, work)
	}

fetch_pinned_libfuzzer! = |root, dependency, work| {
	extract_root = Path.join(Path.join(root, ".test-cache"), "libfuzzer-source")
	source = Path.join(Path.join(extract_root, "libfuzzer-sys-${dependency.version}"), "libfuzzer")
	if Path.is_file!(Path.join(source, "FuzzerMain.cpp"))? {
		return Ok(source)
	}
	Script.info!("DOWNLOAD", "fetching the pinned libFuzzer ${dependency.version} source archive")?
	archive = Path.join(work, "libfuzzer-sys-${dependency.version}.crate")
	Script.command("curl").run!(["--fail", "--location", "--silent", "--show-error", "--output", Path.to_os_str(archive), OsStr.from_str(dependency.url)])?
	actual = Integrity.digest!(archive)?
	expected = dependency.sha256.to_str()
	if actual != expected {
		return Err(LibfuzzerChecksumMismatch(expected, actual))
	}
	Path.create_all!(extract_root)?
	Script.command("tar").run!(["-xzf", Path.to_os_str(archive), "-C", Path.to_os_str(extract_root)])?
	validate_libfuzzer_source!(source)
}

validate_libfuzzer_source! = |source|
	if Path.is_file!(Path.join(source, "FuzzerMain.cpp"))? Ok(source) else Err(IncompleteLibfuzzerSource(source))

build_libraries! = |root, zig, ar, source, work, spec| {
	directory = Project.Target.dir(spec.target, root)
	Path.create_all!(directory)?
	identity = Path.join(directory, "NATIVE_LIBRARIES.json")
	if Path.exists!(identity)? {
		Path.delete!(identity)?
	}
	build_libfuzzer!(root, zig, ar, source, Path.join(directory, "libfuzzer.a"), work, spec)?
	copy_zig_runtime!(zig, directory, work, spec)
}

build_libfuzzer! = |root, zig, ar, source, output, work, spec| {
	object_dir = Path.join(work, "${Project.Target.name(spec.target)}-libfuzzer-objects")
	Path.create_all!(object_dir)?
	cpps = Files.direct_files!(source)?.keep_if(
		|path| {
			name = Path.display(path)
			Script.ends_with(name, ".cpp") and !(Script.ends_with(name, "FuzzerInterceptors.cpp") and !spec.include_fuzzer_interceptors) and !(Script.ends_with(name, "FuzzerExtFunctionsDlsym.cpp") and spec.target == Arm64Mac)
		},
	)
	var $objects = []
	var $index = 0
	for cpp in cpps {
		object = Path.join(object_dir, "fuzzer-${$index.to_str()}.o")
		zig.run!(["c++", "-target", OsStr.from_str(spec.zig_target)].concat(cxx_target_args!(spec)?).concat(["-std=c++17", "-O2", "-fno-omit-frame-pointer", "-fPIC", "-w", "-c", Path.to_os_str(cpp), "-o", Path.to_os_str(object)]))?
		$objects = $objects.append(object)
		$index = $index + 1
	}
	all_objects = if spec.target == Arm64Mac {
		adapter = Path.join(Path.join(root, "src"), "macos_fuzzer_ext_functions.cpp")
		object = Path.join(object_dir, "macos_fuzzer_ext_functions.o")
		zig.run!(["c++", "-target", OsStr.from_str(spec.zig_target)].concat(cxx_target_args!(spec)?).concat(["-I", Path.to_os_str(source), "-std=c++17", "-O2", "-fno-omit-frame-pointer", "-fPIC", "-w", "-c", Path.to_os_str(adapter), "-o", Path.to_os_str(object)]))?
		$objects.append(object)
	} else {
		$objects
	}
	if Path.exists!(output)? {
		Path.delete!(output)?
	}
	ar.args(["rcs", Path.to_os_str(output)].concat(all_objects.map(Path.to_os_str))).exec_cmd!()
}

cxx_target_args! = |spec|
	if spec.target == Arm64Mac {
		sdk = Script.trim(Str.from_utf8_lossy(Script.command("xcrun").capture!(["--show-sdk-path"], ".", [])?))
		if sdk.is_empty() {
			Err(MissingMacosSdk)
		} else {
			Ok(["-isysroot", OsStr.from_str(sdk), "-isystem", OsStr.from_str("${sdk}/usr/include")])
		}
	} else {
		Ok([])
	}

copy_zig_runtime! = |zig, directory, work, spec| {
	probe = Path.join(work, "${Project.Target.name(spec.target)}-runtime_probe.cpp")
	Path.write_utf8!(probe, "int main() { return 0; }\n")?
	executable = Path.join(work, "${Project.Target.name(spec.target)}-runtime_probe")
	args = ["c++", "-target", OsStr.from_str(spec.zig_target)].concat(cxx_target_args!(spec)?).concat(["-O2", "-v", Path.to_os_str(probe)])
	final_args = if spec.target == X64Musl args.append("-static") else args
	output = capture_combined!(zig.cmd(final_args.concat(["-o", Path.to_os_str(executable)])))?
	wanted = spec.input_names.keep_if(|name| name != "libhost.a" and name != "libfuzzer.a")
	var $found = []
	for token in Str.split_on(output, " ") {
		clean = Script.trim(token)
		match wanted.find_first(|name| Script.ends_with(clean, "/${name}")) {
			Ok(name) if !$found.contains(name) => {
				path = Path.utf8(clean)
				if Path.is_file!(path)? {
					Path.copy!(path, Path.join(directory, name))?
					$found = $found.append(name)
				}
			}
			Ok(_) => {}
			Err(_) => {}
		}
	}
	missing = wanted.keep_if(|name| !$found.contains(name))
	if missing.is_empty() Ok({}) else Err(MissingZigRuntimeArtifacts(missing))
}

capture_combined! = |command| {
	output = command.stdout(Capture).stderr(Capture).run!().map_err(|err| CommandRunFailed(err))?
	match output.status {
		Exited(0) => Ok(Str.from_utf8_lossy(output.stdout_bytes.concat(output.stderr_bytes)))
		Exited(code) => Err(CommandExited(code))
		Signaled(signal) => Err(CommandSignaled(signal))
	}
}

build_host! = |root, zig, ar, work, spec| {
	directory = Project.Target.dir(spec.target, root)
	Path.create_all!(directory)?
	sdk_args = if spec.target == Arm64Mac {
		sdk = Script.trim(Str.from_utf8_lossy(Script.command("xcrun").capture!(["--show-sdk-path"], ".", [])?))
		["--sysroot", OsStr.from_str(sdk)]
	} else {
		[]
	}
	host = Path.join(directory, "libhost.a")
	zig.run!(["build-lib", Path.to_os_str(Path.join(Path.join(root, "src"), "main.zig")), "-target", OsStr.from_str(spec.zig_target)].concat(sdk_args).concat(["-O", "ReleaseFast", OsStr.from_str("-femit-bin=${Path.display(host)}"), "-fcompiler-rt", "-lc"]))?
	if spec.target == Arm64Mac {
		stack = Path.join(work, "macos_sancov.o")
		zig.run!(["cc", "-target", OsStr.from_str(spec.zig_target)].concat(cxx_target_args!(spec)?).concat(["-O2", "-fPIC", "-c", Path.to_os_str(Path.join(Path.join(root, "src"), "macos_sancov.c")), "-o", Path.to_os_str(stack)]))?
		ar.args(["rcs", Path.to_os_str(host), Path.to_os_str(stack)]).exec_cmd!()?
	}
	Ok({})
}
