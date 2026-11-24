#!/usr/bin/env roc-stable
app [main!] {
	ansi: "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.3/BioPdu7WjVhTB2j1HaomKMi8htxsuwqwr79GbXY5nAUf.tar.zst",
	arg_path: "https://github.com/roc-lang/path/releases/download/4.0.0/7YfABZPwJAXtLBY2vm8FqMyGAtNxncCJ65HdNKHFGNnE.tar.zst",
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	deflate: "https://github.com/lukewilliamboswell/roc-deflate/releases/download/0.6.0-rc2/CQoQh2ycoMgMbrkSnQJdsEhWjp67fYrT7hWwgQXynEBy.tar.zst",
	roc: "nightly-2026-11-18-a520eed",
	tar: "https://github.com/lukewilliamboswell/roc-tar/releases/download/0.0.3-rc1/8egXmMy7h6TTkRzUmxWygp2GnPe4mBSNGy5Q2ZZYkppu.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.10.2/7CdYzjBAJmprmnK45oTpmH6BXt76ZASN2Ck5uZQEoWsK.tar.zst",
	zip: "https://github.com/lukewilliamboswell/roc-zip/releases/download/0.3.0-rc5/2q3JUnEiL7N5i3cCNq4keScCxg8jgnLxVPJydRnXrr5L.tar.zst",
}

import cli.Cmd
import cli.Env
import cli.OsStr
import cli.Path
import weaver.Base exposing [InvalidValue]
import weaver.Cli
import weaver.Opt
import src/Archive
import src/CliValues
import src/Files
import src/Identity
import src/Integrity
import src/LibrarySource
import src/PlatformInputs
import src/Project
import src/LinkInputs
import src/Script
import src/WeaverCli
import src/NativeDeps

main! = |raw_args| {
	options = match WeaverCli.parse!(cli_parser, raw_args)? {
		Run(parsed) => parsed
		Exit => return Ok({})
	}
	root = Project.root!()?
	dependencies = NativeDeps.current
	library_source = options.libraries
	mode = build_mode!(options.host_only, options.libraries_only, library_source)?
	specs = if (options.target_specs.is_empty()) [Project.host_target!()?.spec()] else options.target_specs
	# Zig sees its search path and a home for its cache, and nothing else. On
	# macOS a development shell sets SDKROOT, and the compiler would record that
	# SDK's version in every object it writes.
	zig = Script.sealed_command!(Path.to_os_str(options.zig), ["PATH", "HOME"])?
	ar = match options.ar {
		CustomAr(program) => Cmd.new(Path.to_os_str(program))
		DefaultAr => zig.cmd(["ar"])
	}
	libfuzzer_source = match options.libfuzzer_source {
		LocalSource(path) if library_source == LibrarySource.Source => LocalSource(Path.absolute!(path)?)
		LocalSource(_) => return Script.fail!("--libfuzzer-source can only be used with --libraries source")
		PinnedSource => PinnedSource
	}
	build = { ar, dependencies, libfuzzer_source, library_source, mode, root, specs, zig }

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
				default: Value(LibrarySource.default),
			}),
			libraries_only: Opt.flag({ short: "", long: "libraries-only", help: "Build only linker inputs for the independent release workflow." }),
			libfuzzer_source: Cli.map(
				Opt.maybe({ short: "", long: "libfuzzer-source", help: "Use a local libFuzzer source tree instead of the pinned source archive.", type: "path", parser: CliValues.path }),
				|value| match value {
					Ok(path) => LocalSource(path)
					Err(NoValue) => PinnedSource
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

parse_library_source_arg : _ -> Try(LibrarySource.LibrarySource, [InvalidNumStr, InvalidValue(Str), InvalidUtf8])
parse_library_source_arg = |argument| CliValues.parse(argument, LibrarySource.parse, "expected release or source")

parse_target_spec_arg : _ -> Try(Project.TargetSpec, [InvalidNumStr, InvalidValue(Str), InvalidUtf8])
parse_target_spec_arg = |argument|
	match CliValues.parse(argument, Project.Target.parse, "unknown platform target") {
		Ok(target) => Ok(target.spec())
		Err(err) => Err(err)
	}

build_mode! = |host_only, libraries_only, library_source|
	if host_only and (libraries_only or library_source != LibrarySource.Release) {
		Script.fail!("--host-only uses existing release libraries, so it cannot be combined with --libraries-only or --libraries source")
	} else if libraries_only and library_source != LibrarySource.Source {
		Script.fail!("--libraries-only builds libraries from source; add --libraries source")
	} else if host_only {
		Ok(HostOnly)
	} else if libraries_only {
		Ok(LibrariesOnly)
	} else {
		Ok(Complete)
	}

## The host is compiled against the committed bindings and never generates
## them, so it builds the same way on every runner. scripts/check_glue.roc
## regenerates and compares them.
prepare_glue! = |build| {
	generated = Path.join(Path.join(build.root, "src"), "roc_platform_abi.zig")
	if build.mode == LibrariesOnly or Path.is_file!(generated)? {
		Ok({})
	} else {
		Script.fail!("the committed host bindings are missing at ${Path.display(generated)}; restore the file or run `blueprint run check-glue -- --update`")
	}
}

build_targets! = |build, work| {
	libfuzzer = if build.library_source == LibrarySource.Source {
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
			LinkInputs.install!(build.root, spec.target, Path.join(build.root, ".test-cache/native-libraries"))?
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
	if Path.exists!(source)? {
		Path.delete_all!(source)?
	}
	_ = Archive.extract_under!(Archive.Format.Tar, archive, "libfuzzer-sys-${dependency.version}/libfuzzer", source, libfuzzer_archive_limit)?
	validate_libfuzzer_source!(source)
}

## The most the libFuzzer crate may hold, decompressed. 0.4.5 holds 572 kB.
libfuzzer_archive_limit : U64
libfuzzer_archive_limit = 64 * 1024 * 1024

validate_libfuzzer_source! = |source|
	if (Path.is_file!(Path.join(source, "FuzzerMain.cpp"))?) Ok(source) else Err(IncompleteLibfuzzerSource(source))

build_libraries! : Path, Script.Command, Cmd.Command, Path, Path, Project.TargetSpec => Try({}, _)
build_libraries! = |root, zig, ar, source, work, spec| {
	directory = Project.Target.dir(spec.target, root)
	Path.create_all!(directory)?
	identity = Path.join(directory, "NATIVE_LIBRARIES.json")
	if Path.exists!(identity)? {
		Path.delete!(identity)?
	}
	build_libfuzzer!(root, zig, ar, source, Path.join(directory, "libfuzzer.a"), work, spec)?
	copy_zig_runtime!(root, zig, ar, directory, work, spec)
}

build_libfuzzer! : Path, Script.Command, Cmd.Command, Path, Path, Path, Project.TargetSpec => Try({}, _)
build_libfuzzer! = |root, zig, ar, source, output, work, spec| {
	object_dir = Path.join(work, "${Project.Target.name(spec.target)}-libfuzzer-objects")
	Path.create_all!(object_dir)?
	cpps = Files.direct_files!(source)?.keep_if(
		|path| {
			name = Path.display(path)
			Script.ends_with(name, ".cpp") and !(Script.ends_with(name, "FuzzerInterceptors.cpp") and !spec.include_fuzzer_interceptors) and !(Script.ends_with(name, "FuzzerExtFunctionsDlsym.cpp") and spec.target == Project.Target.Arm64Mac)
		},
	)
	var $objects = []
	var $index = 0
	for cpp in cpps {
		object = Path.join(object_dir, "fuzzer-${$index.to_str()}.o")
		zig.run!(["c++", "-target", OsStr.from_str(spec.zig_target)].concat(cxx_target_args(root, spec)).concat(["-std=c++17", "-O2", "-g0", "-fno-omit-frame-pointer", "-fPIC", "-w", "-c", Path.to_os_str(cpp), "-o", Path.to_os_str(object)]))?
		$objects = $objects.append(object)
		$index = $index + 1
	}
	all_objects = if spec.target == Project.Target.Arm64Mac {
		adapter = Path.join(Path.join(root, "src"), "macos_fuzzer_ext_functions.cpp")
		object = Path.join(object_dir, "macos_fuzzer_ext_functions.o")
		zig.run!(["c++", "-target", OsStr.from_str(spec.zig_target)].concat(cxx_target_args(root, spec)).concat(["-I", Path.to_os_str(source), "-std=c++17", "-O2", "-g0", "-fno-omit-frame-pointer", "-fPIC", "-w", "-c", Path.to_os_str(adapter), "-o", Path.to_os_str(object)]))?
		$objects.append(object)
	} else {
		$objects
	}
	if Path.exists!(output)? {
		Path.delete!(output)?
	}
	ar.args([archive_flags, Path.to_os_str(output)].concat(all_objects.map(Path.to_os_str))).call!()
}

## Every library is byte-reproducible: the same sources, Zig release and flags
## give the same bytes on any machine, in any directory, at any time. Three
## things would otherwise leak the build's surroundings into the output.
##
## * Debug information records the absolute paths of Zig's installation, its
##   cache and the working directory, so nothing is compiled with it: `-g0` for
##   C and C++, `-s` for the link that makes Zig build its runtimes, and
##   `-fstrip` for the host.
## * Zig names an archive member after its cache path, which holds a hash of
##   those same directories and, for the host, a random one. `flatten_archive!`
##   renames members to their file names.
## * An archiver may record times and owners. `D` writes zeros.
##
## Zig also runs with a sealed environment; see `main!`.
archive_flags = "rcsD"

## The macOS target is compiled against the headers Zig bundles, on any host.
## The build reads no installed Apple SDK. `src/macos_compat` supplies the one
## header libFuzzer includes that Zig does not carry.
cxx_target_args : Path, Project.TargetSpec -> List(OsStr)
cxx_target_args = |root, spec|
	if spec.target == Project.Target.Arm64Mac {
		["-isystem", Path.to_os_str(Path.join(root, "src/macos_compat"))]
	} else {
		[]
	}

## Rewrite an archive so that each member is named by its file name alone, in
## the original order. Members that share a file name keep it with a counter,
## as `clone.2.o`; musl's `libc.a` has two `clone.o`.
flatten_archive! : Cmd.Command, Path, Path, Str => Try({}, _)
flatten_archive! = |ar, archive, work, label| {
	listed = Str.from_utf8_lossy(Script.run_capture!(ar, ["t", Path.to_os_str(archive)], work, [])?)
	members = Str.split_on(listed, "\n").keep_if(|member| !member.is_empty())
	if !members.any(|member| member.contains("/")) {
		return Ok({})
	}
	extracted = Path.join(work, "${label}-members")
	renamed = Path.join(extracted, "flat")
	Path.create_all!(renamed)?
	var $seen = []
	var $flat = []
	for member in members {
		base = Str.split_on(member, "/").last().map_err(|_| EmptyArchiveMember(Path.display(archive)))?
		# `P` matches the full member name, which is what tells duplicates apart.
		_ = Script.run_capture!(ar, ["xP", Path.to_os_str(archive), OsStr.from_str(member)], extracted, [])?
		earlier = $seen.keep_if(|name| name == base).len()
		name = if (earlier == 0) base else Str.replace_each(base, ".o", ".${(earlier + 1).to_str()}.o")
		$seen = $seen.append(base)
		Path.rename!(Path.join(extracted, base), Path.join(renamed, name))?
		$flat = $flat.append(Path.join(renamed, name))
	}
	Path.delete!(archive)?
	ar.args([archive_flags, Path.to_os_str(archive)].concat($flat.map(Path.to_os_str))).call!()
}

copy_zig_runtime! : Path, Script.Command, Cmd.Command, Path, Path, Project.TargetSpec => Try({}, _)
copy_zig_runtime! = |root, zig, ar, directory, work, spec| {
	probe = Path.join(work, "${Project.Target.name(spec.target)}-runtime_probe.cpp")
	Path.write_utf8!(probe, "int main() { return 0; }\n")?
	executable = Path.join(work, "${Project.Target.name(spec.target)}-runtime_probe")
	args = ["c++", "-target", OsStr.from_str(spec.zig_target)].concat(cxx_target_args(root, spec)).concat(["-O2", "-s", "-v", "-fPIC", Path.to_os_str(probe)])
	# Static PIE selects musl's self-relocating startup and PIC runtimes.
	final_args = if (spec.target == Project.Target.X64Musl) args.concat(["-static", "-pie"]) else args
	output = capture_combined!(zig.cmd(final_args.concat(["-o", Path.to_os_str(executable)])))?
	wanted = spec.input_names.keep_if(|name| name != "libhost.a" and name != "libfuzzer.a")
	var $found = []
	for token in Str.split_on(output, " ") {
		clean = Script.trim(token)
		match wanted.find_first(|name| Script.ends_with(clean, "/${name}")) {
			Ok(name) if !$found.contains(name) => {
				path = Path.utf8(clean)
				if Path.is_file!(path)? {
					copied = Path.join(directory, name)
					Path.copy!(path, copied)?
					if Script.ends_with(name, ".a") {
						flatten_archive!(ar, copied, work, "${Project.Target.name(spec.target)}-${name}")?
					}
					$found = $found.append(name)
				}
			}
			Ok(_) => {}
			Err(_) => {}
		}
	}
	missing = wanted.keep_if(|name| !$found.contains(name))
	if (missing.is_empty()) Ok({}) else Err(MissingZigRuntimeArtifacts(missing))
}

capture_combined! : Cmd.Command => Try(Str, _)
capture_combined! = |command| {
	output = command.stdout(Capture).stderr(Capture).run!().map_err(|err| CommandRunFailed(err))?
	match output.status {
		Exited(0) => Ok(Str.from_utf8_lossy(output.stdout_bytes.concat(output.stderr_bytes)))
		Exited(code) => Err(CommandExited(code))
		Signaled(signal) => Err(CommandSignaled(signal))
	}
}

build_host! : Path, Script.Command, Cmd.Command, Path, Project.TargetSpec => Try({}, _)
build_host! = |root, zig, ar, work, spec| {
	directory = Project.Target.dir(spec.target, root)
	Path.create_all!(directory)?
	host = Path.join(directory, "libhost.a")
	zig.run!(["build-lib", Path.to_os_str(Path.join(Path.join(root, "src"), "main.zig")), "-target", OsStr.from_str(spec.zig_target)].concat(["-O", "ReleaseFast", "-fPIC", "-fstrip", OsStr.from_str("-femit-bin=${Path.display(host)}"), "-fcompiler-rt", "-lc"]))?
	if spec.target == Project.Target.Arm64Mac {
		stack = Path.join(work, "macos_sancov.o")
		zig.run!(["cc", "-target", OsStr.from_str(spec.zig_target)].concat(cxx_target_args(root, spec)).concat(["-O2", "-g0", "-fPIC", "-c", Path.to_os_str(Path.join(Path.join(root, "src"), "macos_sancov.c")), "-o", Path.to_os_str(stack)]))?
		ar.args([archive_flags, Path.to_os_str(host), Path.to_os_str(stack)]).call!()?
	}
	flatten_archive!(ar, host, work, "${Project.Target.name(spec.target)}-libhost.a")
}
