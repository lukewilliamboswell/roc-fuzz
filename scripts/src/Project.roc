import cli.Env
import cli.Path

## Repository layout and native target definitions.
Project := [].{
	Target := [Arm64Mac, X64Musl].{
		parse = |name| match name {
			"x64musl" => Ok(Target.X64Musl)
			"arm64mac" => Ok(Target.Arm64Mac)
			_ => Err(UnknownTarget(name))
		}

		name = |self| match self {
			X64Musl => "x64musl"
			Arm64Mac => "arm64mac"
		}

		spec = |self| match self {
			X64Musl => TargetSpec.{
				target: self,
				zig_target: "x86_64-linux-musl",
				input_names: ["crt1.o", "libhost.a", "libfuzzer.a", "libc++.a", "libc++abi.a", "libunwind.a", "libc.a", "libzigc.a", "libcompiler_rt.a"],
				include_fuzzer_interceptors: Bool.False,
			}
			Arm64Mac => TargetSpec.{
				target: self,
				zig_target: "aarch64-macos.11.0",
				input_names: ["libhost.a", "libfuzzer.a", "libc++abi.a", "libc++.a", "libcompiler_rt.a"],
				include_fuzzer_interceptors: Bool.True,
			}
		}

		dir = |self, root| Path.join(
			Path.join(Path.join(root, "platform"), "targets"),
			match self {
				X64Musl => "x64musl"
				Arm64Mac => "arm64mac"
			},
		)

		is_eq = |left, right| left.name() == right.name()
	}

	TargetSpec := {
		target : Target,
		zig_target : Str,
		input_names : List(Str),
		include_fuzzer_interceptors : Bool,
	}.{}

	root! : () => Try(Path, _)
	root! = || {
		root = Env.cwd!()?
		if Path.is_file!(Path.join(root, "platform/main.roc"))? and Path.is_dir!(Path.join(root, "examples"))? {
			Ok(root)
		} else {
			Err(NotRepositoryRoot(Path.display(root)))
		}
	}

	all_targets : List(Target)
	all_targets = [Target.X64Musl, Target.Arm64Mac]
	public_modules = ["Arbitrary", "Fuzz", "Target"]
	target_specs = all_targets.map(|target| target.spec())

	host_target! : () => Try(Target, _)
	host_target! = || {
		host = Env.platform!()
		match (host.os, host.arch) {
			(LINUX, X64) => Ok(Target.X64Musl)
			(MACOS, AARCH64) => Ok(Target.Arm64Mac)
			_ => Err(UnsupportedHost(host.os, host.arch))
		}
	}

	library_names = |spec| spec.input_names.keep_if(|name| name != "libhost.a")
}

expect match Project.Target.parse("x64musl") {
	Ok(target) => target.name() == "x64musl"
	Err(_) => Bool.False
}
expect Project.Target.parse("windows") |> Try.is_err
expect Project.Target.(X64Musl) != Project.Target.(Arm64Mac)
