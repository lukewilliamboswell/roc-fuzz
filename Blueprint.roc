# Development environment and tasks for roc-fuzz, realised by roc-blueprint with Nix.
#
#     blueprint run check    # everything a pull request must pass
#     blueprint shell        # the environment, to run scripts/*.roc directly
#     blueprint tasks        # list the declared tasks
#     blueprint update       # refresh Blueprint.lock
#
# Two compilers are in play and are not interchangeable. `roc-stable` is the
# release named below; it runs the scripts under scripts/. The platform and its
# targets are checked, built and run with whatever `roc` is on PATH, which is
# meant to be the latest nightly, so nothing here provides a bare `roc`.
app [config] { pf: platform "https://github.com/lukewilliamboswell/roc-blueprint/releases/download/0.4.0/4jmnCGtQeuXTJJYc1rPrnA1pQFPRqUecY5oau1te8cYn.tar.zst" }

config = [
	Name("roc-fuzz"),
	Overlay("roc", "github:roc-lang/roc-overlay"),
	Environment(
		"dev",
		[
			Overlays(["roc"]),
			Command("roc-stable", "rocpkgs.nightly-2026-09-29-7f11a82"),
			# Every bundle the scripts depend on, including dependencies of
			# dependencies: `roc-stable deps scripts/check_all.roc` lists them.
			RocPackages([
				"https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst",
				"https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
				"https://github.com/Hasnep/roc-ascii/releases/download/v0.5.0/5WxqRf15XVko4HxVq5dW8r84s95CxrtvzrjZYwbg9Z3H.tar.zst",
				"https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.0/JXLM47L6CzrLXB5HBfqc27VnU6CD4jMm5Mk6dgbbovL.tar.zst",
				"https://github.com/roc-lang/path/releases/download/4.0.0/7YfABZPwJAXtLBY2vm8FqMyGAtNxncCJ65HdNKHFGNnE.tar.zst",
				"https://github.com/lukewilliamboswell/weaver/releases/download/0.9.0/7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77.tar.zst",
			]),
			# Programs the scripts and workflows start. Zig is not here yet: an
			# exact Zig release needs a tool name Blueprint cannot express until
			# its next release, so CI installs it and contributors provide it.
			Tools(["coreutils", "gh", "git", "jq", "unzip", "zip"]),
		],
	),
	Shell("default", [Use("dev")]),
	# Everything a pull request must pass that does not depend on the target.
	Task("check", [Use("dev"), Run(["scripts/check_all.roc"])]),
	Task("check-supply-chain", [Use("dev"), Run(["scripts/check_supply_chain.roc", "--"])]),
	Task("native-sanitizers", [Use("dev"), Run(["scripts/test_native_sanitizers.roc"])]),
	# The host and its linker inputs. Arguments follow `--`, for example
	# `blueprint run build-platform -- --target x64musl`.
	Task("build-platform", [Use("dev"), Run(["scripts/build_platform.roc", "--"])]),
	Task("link-inputs", [Use("dev"), Run(["scripts/link_input_artifacts.roc", "--"])]),
	Task("check-link-inputs", [Use("dev"), Run(["scripts/check_native_libraries.roc", "--"])]),
	# Targets: check, build and run the cases in tests/targets.json.
	Task("test-targets", [Use("dev"), Run(["scripts/test_targets.roc", "--"])]),
	Task("run-target", [Use("dev"), Run(["scripts/run_target.roc", "--"])]),
	# The steps of a release, which .github/workflows/release.yml runs in order.
	Task("bundle", [Use("dev"), Run(["scripts/build_bundle.roc", "--"])]),
	Task("test-bundle", [Use("dev"), Run(["scripts/test_bundle.roc", "--"])]),
	Task("release-examples", [Use("dev"), Run(["scripts/release_examples.roc", "--"])]),
	Task("release-notes", [Use("dev"), Run(["scripts/render_release_notes.roc", "--"])]),
	Task("sbom", [Use("dev"), Run(["scripts/build_release_sbom.roc", "--"])]),
	Task("stable-version", [Use("dev"), Run(["roc-stable", "version"])]),
	# The manual and the API reference.
	Task("docs", [Use("dev"), Run(["scripts/build_docs.roc", "--"])]),
	Task("check-docs", [Use("dev"), Run(["scripts/check_docs.roc", "--"])]),
]
