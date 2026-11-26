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
app [config] { pf: platform "https://github.com/lukewilliamboswell/roc-blueprint/releases/download/0.15.0-rc.1/FwWWY6PczB7QsUoWKgaLTuBGGajLjfA4MhaLD36sJxrN.tar.zst" }

import pf.Config
import pf.Recipes
import pf.System

config = [
	Name("roc-fuzz"),
	Systems(["x86_64-linux", "aarch64-linux", "aarch64-darwin"]),
	Packages("nix", From(NixPackages("github:NixOS/nixpkgs/nixos-unstable"))),
	Environment(
		"dev",
		[
			Programs([
				Fetch("zig", zig_archive),
				Fetch("roc-stable", Recipes.roc_nightly("nightly-2026-11-25-d5a4f1e")),
				# The shared documentation renderer, as actions/build-docs runs it.
				Fetch("roc-docs", Recipes.file("https://github.com/lukewilliamboswell/roc-automation/releases/download/tools-0.12.0/roc-docs-{system}")),
			]),
			# Every bundle the scripts depend on, including dependencies of
			# dependencies: `roc-stable deps scripts/check_all.roc` lists them.
			RocPackages([
				"https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
				"https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
				"https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.3/BioPdu7WjVhTB2j1HaomKMi8htxsuwqwr79GbXY5nAUf.tar.zst",
				"https://github.com/roc-lang/path/releases/download/4.0.0/7YfABZPwJAXtLBY2vm8FqMyGAtNxncCJ65HdNKHFGNnE.tar.zst",
				"https://github.com/lukewilliamboswell/weaver/releases/download/0.10.2/7CdYzjBAJmprmnK45oTpmH6BXt76ZASN2Ck5uZQEoWsK.tar.zst",
				"https://github.com/lukewilliamboswell/roc-tar/releases/download/0.0.3-rc1/8egXmMy7h6TTkRzUmxWygp2GnPe4mBSNGy5Q2ZZYkppu.tar.zst",
				"https://github.com/lukewilliamboswell/roc-zip/releases/download/0.3.0-rc6/CxK9QaRb2VBQn2hKHAmSQ1zFYW2AGNC6XLuDXeHDamZY.tar.zst",
				"https://github.com/niclas-ahden/roc-crc32/releases/download/2.0.1/GVgp4MNmCBjdtJg8j2gBdsrdsKKyx4huzRz7ZtbRaYvJ.tar.zst",
				"https://github.com/lukewilliamboswell/roc-deflate/releases/download/0.6.0-rc2/CQoQh2ycoMgMbrkSnQJdsEhWjp67fYrT7hWwgQXynEBy.tar.zst",
			]),
			Tools(["nix#coreutils", "nix#gh", "nix#git", "nix#jq"]),
			Expect(["sh"]),
		],
	),
	Shell("default", [Use("dev")]),
	# Everything a pull request must pass that does not depend on the target.
	Task("check", [Use("dev"), Run(["scripts/check_all.roc"])]),
	Task("check-supply-chain", [Use("dev"), Run(["scripts/check_supply_chain.roc"])]),
	Task("test-quality", [Use("dev"), Run(["scripts/test_quality.roc"])]),
	Task("native-sanitizers", [Use("dev"), Run(["scripts/test_native_sanitizers.roc"])]),
	# The host and its linker inputs. Arguments follow `--`, for example
	# `blueprint run build-platform -- --target x64musl`.
	Task("build-platform", [Use("dev"), Run(["scripts/build_platform.roc"])]),
	# Compare the committed host bindings with what `roc glue` generates;
	# `-- --update` rewrites them.
	Task("check-glue", [Use("dev"), Run(["scripts/check_glue.roc"])]),
	Task("link-inputs", [Use("dev"), Run(["scripts/link_input_artifacts.roc"])]),
	Task("check-link-inputs", [Use("dev"), Run(["scripts/check_native_libraries.roc"])]),
	# Targets: check, build and run the cases in tests/targets.json.
	Task("test-targets", [Use("dev"), Run(["scripts/test_targets.roc"])]),
	Task("run-target", [Use("dev"), Run(["scripts/run_target.roc"])]),
	# The steps of a release, which .github/workflows/release.yml runs in order.
	Task("bundle", [Use("dev"), Run(["scripts/build_bundle.roc"])]),
	Task("test-bundle", [Use("dev"), Run(["scripts/test_bundle.roc"])]),
	Task("release-examples", [Use("dev"), Run(["scripts/release_examples.roc"])]),
	Task("release-notes", [Use("dev"), Run(["scripts/render_release_notes.roc"])]),
	Task("stable-version", [Use("dev"), Run(["roc-stable", "version"])]),
	# The manual and the API reference.
	Task("docs", [Use("dev"), Run(["scripts/build_docs.roc"])]),
	Task("check-docs", [Use("dev"), Run(["scripts/check_docs.roc"])]),
	# The renderer's persistent path, for actions/blueprint-tool to hand to
	# actions/build-docs.
	Task("docs-path", [Use("dev"), Run(["sh", "-c", "realpath \"$(command -v roc-docs)\""])]),
	# The Pages site: the latest release's documentation, with the working
	# tree's under unreleased/. Run `docs` first.
	Task("site", [Use("dev"), Run(["scripts/build_site.roc"])]),
]

zig_archive : System -> Config.Download
zig_archive = |system| {
	machine = match system {
		"x86_64-linux" => "x86_64-linux"
		"aarch64-linux" => "aarch64-linux"
		"aarch64-darwin" => "aarch64-macos"
		_ => return Unavailable
	}
	version = "0.17.1"
	name = "zig-${machine}-${version}"
	Archive("https://ziglang.org/download/${version}/${name}.tar.xz", TarXz, "${name}/zig")
}
