#!/usr/bin/env python3
from __future__ import annotations

import argparse
import contextlib
import functools
import http.server
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import urllib.parse
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC_PATH = ROOT / "scripts" / "test_spec.json"
PIN_PATH = ROOT / ".roc-version"
STAGES = ("check", "test", "build", "seed", "fuzz")
TARGET_KEYS = frozenset({"name", "path", "seed_hex", "libfuzzer_seed", "stages"})
RETIRED_KEYS = frozenset({"name", "reason"})
PROXY_VARIABLES = ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy")


class TestFailure(Exception):
    pass


def read_pin() -> str:
    lines = [line.strip() for line in PIN_PATH.read_text(encoding="utf-8").splitlines()]
    if len(lines) != 1 or not lines[0].startswith("nightly-"):
        raise TestFailure(".roc-version must contain exactly one Roc nightly tag")
    return lines[0]


def compiler_matches_pin(version: str, pin: str) -> bool:
    reported = version.split()[-1] if version.split() else version
    if reported == pin:
        return True
    revision = pin.rsplit("-", 1)[-1]
    reported_revision = reported.rsplit("-", 1)[-1]
    return (
        len(revision) >= 7
        and reported_revision.startswith(revision)
        and all(character in "0123456789abcdefABCDEF" for character in reported_revision)
    )


def run(
    command: list[str],
    *,
    cwd: Path = ROOT,
    env: dict[str, str] | None = None,
    verbose: bool = False,
) -> None:
    if verbose:
        print("+", " ".join(command), flush=True)
    result = subprocess.run(command, cwd=cwd, env=env, text=True, capture_output=not verbose)
    if result.returncode != 0:
        if not verbose:
            if result.stdout:
                print(result.stdout, end="", file=sys.stdout)
            if result.stderr:
                print(result.stderr, end="", file=sys.stderr)
        raise TestFailure(f"command failed with exit code {result.returncode}: {' '.join(command)}")


def run_expect_failure(
    command: list[str],
    *,
    env: dict[str, str],
    verbose: bool,
) -> str:
    if verbose:
        print("+", " ".join(command), "# expected failure", flush=True)
    result = subprocess.run(command, cwd=ROOT, env=env, text=True, capture_output=True)
    output = f"{result.stdout}{result.stderr}"
    if result.returncode == 0:
        if output:
            print(output, end="", file=sys.stderr)
        raise TestFailure(f"command unexpectedly succeeded: {' '.join(command)}")
    return output


def load_spec() -> tuple[dict[str, bool], list[dict[str, object]], list[dict[str, str]]]:
    data = json.loads(SPEC_PATH.read_text(encoding="utf-8"))
    if set(data) != {"stages", "targets", "retired"}:
        raise TestFailure("test_spec.json must contain exactly stages, targets, and retired")

    stages = data["stages"]
    if not isinstance(stages, dict) or set(stages) != set(STAGES):
        raise TestFailure(f"stages must define exactly {', '.join(STAGES)}")
    if not all(isinstance(stages[stage], bool) for stage in STAGES):
        raise TestFailure("every stage default must be a boolean")

    targets = data["targets"]
    if not isinstance(targets, list) or not all(isinstance(item, dict) for item in targets):
        raise TestFailure("targets must be an array of objects")
    names: set[str] = set()
    paths: set[str] = set()
    for item in targets:
        unknown = set(item) - TARGET_KEYS
        if unknown:
            raise TestFailure(f"target has unknown keys: {sorted(unknown)}")
        name = item.get("name")
        path = item.get("path")
        seed_hex = item.get("seed_hex")
        rng_seed = item.get("libfuzzer_seed")
        overrides = item.get("stages", {})
        if not isinstance(name, str) or not name:
            raise TestFailure("every target needs a non-empty name")
        if name in names:
            raise TestFailure(f"duplicate target name: {name}")
        names.add(name)
        expected_path = f"examples/{name}.roc"
        if path != expected_path or path in paths:
            raise TestFailure(f"target {name} must use unique path {expected_path}")
        paths.add(path)
        if not isinstance(seed_hex, str) or not seed_hex or len(seed_hex) % 2:
            raise TestFailure(f"{name}: seed_hex must be a non-empty even-length string")
        try:
            bytes.fromhex(seed_hex)
        except ValueError as error:
            raise TestFailure(f"{name}: invalid seed_hex") from error
        if not isinstance(rng_seed, int) or not 1 <= rng_seed <= 2_147_483_647:
            raise TestFailure(f"{name}: libfuzzer_seed must be a positive 32-bit integer")
        if not isinstance(overrides, dict) or set(overrides) - set(STAGES):
            raise TestFailure(f"{name}: invalid stage overrides")
        if not all(isinstance(value, bool) for value in overrides.values()):
            raise TestFailure(f"{name}: stage overrides must be booleans")

    discovered = {path.relative_to(ROOT).as_posix() for path in (ROOT / "examples").glob("*.roc")}
    if discovered != paths:
        raise TestFailure(
            f"test spec does not match discovered targets; missing={sorted(discovered - paths)}, "
            f"extra={sorted(paths - discovered)}"
        )

    retired = data["retired"]
    if not isinstance(retired, list) or not all(isinstance(item, dict) for item in retired):
        raise TestFailure("retired must be an array of objects")
    retired_names: set[str] = set()
    for item in retired:
        if set(item) != RETIRED_KEYS:
            raise TestFailure("each retired target must contain exactly name and reason")
        name = item["name"]
        reason = item["reason"]
        if not isinstance(name, str) or not isinstance(reason, str) or not reason.strip():
            raise TestFailure("retired target names and reasons must be non-empty strings")
        if name in names or name in retired_names:
            raise TestFailure(f"duplicate active or retired target: {name}")
        retired_names.add(name)

    return stages, targets, retired


def stage_enabled(defaults: dict[str, bool], target: dict[str, object], stage: str) -> bool:
    overrides = target.get("stages", {})
    assert isinstance(overrides, dict)
    return bool(overrides.get(stage, defaults[stage]))


def select_targets(targets: list[dict[str, object]], requested: list[str] | None) -> list[dict[str, object]]:
    if not requested:
        return targets
    by_name = {str(target["name"]): target for target in targets}
    unknown = sorted(set(requested) - set(by_name))
    if unknown:
        raise TestFailure(f"unknown targets: {', '.join(unknown)}")
    return [by_name[name] for name in requested]


def resolve_compiler(roc: str) -> tuple[str, str, bool]:
    resolved = shutil.which(roc) if os.sep not in roc else roc
    if not resolved:
        raise TestFailure(f"Roc compiler not found: {roc}")
    try:
        version = subprocess.check_output([resolved, "version"], text=True).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise TestFailure(f"failed to query Roc compiler: {error}") from error
    pinned = compiler_matches_pin(version, read_pin())
    if not pinned and os.environ.get("ROC_ALLOW_UNPINNED") != "1":
        raise TestFailure(
            f"compiler reports {version!r}, which does not match .roc-version; "
            "set ROC_ALLOW_UNPINNED=1 only for intentional compiler development"
        )
    return str(Path(resolved).resolve()), version, pinned


def cargo_archive_environment(
    archive: Path,
    base_environment: dict[str, str],
    *,
    non_pic: bool = False,
) -> dict[str, str]:
    environment = base_environment.copy()
    environment.pop("ROC_FUZZ_APP", None)
    environment.pop("ROC_FUZZ_TARGET", None)
    environment.pop("ROC_FUZZ_INSTRUMENT", None)
    environment["ROC_FUZZ_ARCHIVE"] = str(archive.resolve())
    if non_pic:
        rustflags = environment.get("RUSTFLAGS", "")
        environment["RUSTFLAGS"] = f"{rustflags} -C link-arg=-no-pie".strip()
    return environment


def require_fuzz_compiler(roc: str) -> None:
    help_text = subprocess.check_output([roc, "build", "--help"], text=True)
    if "--fuzz" not in help_text:
        raise TestFailure("the selected Roc compiler does not support `roc build --fuzz`")
    if shutil.which("cargo-fuzz") is None and "fuzz" not in subprocess.check_output(
        ["cargo", "--list"], text=True
    ):
        raise TestFailure("cargo-fuzz is not installed; run `cargo install cargo-fuzz`")


def make_corpus(root: Path, target: dict[str, object]) -> Path:
    corpus = root / str(target["name"])
    corpus.mkdir(parents=True, exist_ok=True)
    (corpus / "seed").write_bytes(bytes.fromhex(str(target["seed_hex"])))
    return corpus


def consumer_environment(suite_root: Path) -> dict[str, str]:
    environment = os.environ.copy()
    for name in PROXY_VARIABLES:
        environment.pop(name, None)
    directories = {
        "XDG_CACHE_HOME": suite_root / "cache",
        "ZIG_LOCAL_CACHE_DIR": suite_root / "zig-cache",
        "TMPDIR": suite_root / "tmp",
    }
    for name, directory in directories.items():
        directory.mkdir(parents=True)
        environment[name] = str(directory)
    environment["TEMP"] = environment["TMPDIR"]
    environment["TMP"] = environment["TMPDIR"]
    return environment


def build_bundle(
    roc: str,
    output_dir: Path,
    *,
    environment: dict[str, str],
    verbose: bool,
) -> Path:
    output_dir.mkdir(parents=True)
    run(
        [
            roc,
            "bundle",
            "main.roc",
            "--output-dir",
            str(output_dir),
            "--compression",
            "1",
        ],
        cwd=ROOT / "platform",
        env=environment,
        verbose=verbose,
    )
    bundles = list(output_dir.glob("*.tar.zst"))
    if len(bundles) != 1:
        raise TestFailure(f"expected one fresh platform bundle, found {len(bundles)}")
    return bundles[0]


@contextlib.contextmanager
def serve_bundle(bundle: Path):
    requests: list[str] = []

    class QuietHandler(http.server.SimpleHTTPRequestHandler):
        def do_GET(self) -> None:
            requests.append(self.path)
            super().do_GET()

        def log_message(self, format: str, *args: object) -> None:
            return

    handler = functools.partial(QuietHandler, directory=str(bundle.parent))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    host, port = server.server_address
    url = f"http://{host}:{port}/{urllib.parse.quote(bundle.name)}"
    try:
        yield url, requests
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def rewrite_platform_source(source: Path, destination: Path, bundle_url: str) -> None:
    pattern = re.compile(r'\bplatform\s+"[^"]+"')
    destination.parent.mkdir(parents=True, exist_ok=True)
    contents = source.read_text(encoding="utf-8")
    rewritten, count = pattern.subn(f'platform "{bundle_url}"', contents, count=1)
    if count != 1:
        raise TestFailure(f"expected one platform dependency in {source}")
    destination.write_text(rewritten, encoding="utf-8")


def rewrite_examples(output_root: Path, bundle_url: str) -> None:
    for source in sorted((ROOT / "examples").glob("*.roc")):
        destination = output_root / "examples" / source.name
        rewrite_platform_source(source, destination, bundle_url)


def verify_failure_artifact(
    *,
    roc: str,
    suite_root: Path,
    bundle_url: str,
    environment: dict[str, str],
    verbose: bool,
) -> None:
    source = suite_root / "failure-artifact" / "failureArtifact.roc"
    rewrite_platform_source(ROOT / "platform" / "tests" / "failureArtifact.roc", source, bundle_url)
    archive = source.parent / "failureArtifact.a"
    run(
        [
            roc,
            "build",
            str(source),
            "--fuzz",
            "--target=x64musl",
            "--opt=speed",
            f"--output={archive}",
        ],
        env=environment,
        verbose=verbose,
    )

    corpus = source.parent / "corpus"
    corpus.mkdir()
    seed = b"\x00"
    (corpus / "seed").write_bytes(seed)
    artifact = source.parent / "replayable-crash"
    output = run_expect_failure(
        [
            "cargo",
            "fuzz",
            "run",
            "--sanitizer=none",
            "roc-fuzz",
            str(corpus),
            "--",
            "-runs=1",
            f"-exact_artifact_path={artifact}",
        ],
        env=cargo_archive_environment(archive, environment),
        verbose=verbose,
    )
    if not artifact.is_file() or artifact.read_bytes() != seed:
        if output:
            print(output, end="", file=sys.stderr)
        raise TestFailure("Roc failure did not produce the expected replayable libFuzzer artifact")
    print("PASS failure artifact")


def run_consumer_stages(
    *,
    defaults: dict[str, bool],
    targets: list[dict[str, object]],
    selected_stages: set[str],
    roc: str,
    verbose: bool,
    max_total_time: int,
) -> None:
    cache_dir = ROOT / ".test-cache"
    cache_dir.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="consumer-suite-", dir=cache_dir) as temporary:
        suite_root = Path(temporary)
        environment = consumer_environment(suite_root)
        bundle = build_bundle(
            roc,
            suite_root / "bundle",
            environment=environment,
            verbose=verbose,
        )
        print(f"PASS bundle: {bundle.name}")

        with serve_bundle(bundle) as (bundle_url, requests):
            rewrite_examples(suite_root, bundle_url)

            if "check" in selected_stages:
                for target in targets:
                    if stage_enabled(defaults, target, "check"):
                        source = suite_root / str(target["path"])
                        run([roc, "check", str(source)], env=environment, verbose=verbose)
                        print(f"PASS check: {target['name']}")

            if "test" in selected_stages:
                for target in targets:
                    if stage_enabled(defaults, target, "test"):
                        source = suite_root / str(target["path"])
                        run([roc, "test", str(source)], env=environment, verbose=verbose)
                        print(f"PASS test: {target['name']}")

                glue_environment = environment.copy()
                for name in PROXY_VARIABLES:
                    if name in os.environ:
                        glue_environment[name] = os.environ[name]
                glue_environment["ROC"] = roc
                run(
                    [sys.executable, "scripts/generate_rust_glue.py", "--check", "--roc", roc],
                    env=glue_environment,
                    verbose=verbose,
                )
                host_archive_dir = suite_root / "host-test"
                host_archive_dir.mkdir()
                host_archive = host_archive_dir / "libroc_fuzz.a"
                run(
                    [
                        roc,
                        "build",
                        str(suite_root / "examples" / "noop.roc"),
                        "--target=x64musl",
                        "--opt=speed",
                        f"--output={host_archive}",
                    ],
                    env=environment,
                    verbose=verbose,
                )
                run(
                    ["cargo", "test"],
                    env=cargo_archive_environment(host_archive, environment, non_pic=True),
                    verbose=verbose,
                )
                run(
                    [sys.executable, "scripts/test_driver.py"],
                    verbose=verbose,
                )
                print("PASS host and driver tests")

            if "build" in selected_stages:
                output_dir = suite_root / "archives"
                output_dir.mkdir()
                for target in targets:
                    if not stage_enabled(defaults, target, "build"):
                        continue
                    source = suite_root / str(target["path"])
                    archive = output_dir / f"{target['name']}.a"
                    run(
                        [
                            roc,
                            "build",
                            str(source),
                            "--target=x64musl",
                            "--opt=speed",
                            f"--output={archive}",
                        ],
                        env=environment,
                        verbose=verbose,
                    )
                    if not archive.is_file():
                        raise TestFailure(f"Roc did not produce {archive}")
                    print(f"PASS build: {target['name']}")

            if {"seed", "fuzz"} & selected_stages:
                require_fuzz_compiler(roc)
                corpus_root = suite_root / "corpus"
                archive_root = suite_root / "fuzz-archives"
                archive_root.mkdir()
                for stage in ("seed", "fuzz"):
                    if stage not in selected_stages:
                        continue
                    for target in targets:
                        if not stage_enabled(defaults, target, stage):
                            continue
                        source = suite_root / str(target["path"])
                        corpus = make_corpus(corpus_root, target)
                        archive = archive_root / f"{target['name']}.a"
                        run(
                            [
                                roc,
                                "build",
                                str(source),
                                "--fuzz",
                                "--target=x64musl",
                                "--opt=speed",
                                f"--output={archive}",
                            ],
                            env=environment,
                            verbose=verbose,
                        )
                        if not archive.is_file():
                            raise TestFailure(f"Roc did not produce {archive}")
                        libfuzzer_args = [
                            f"-seed={target['libfuzzer_seed']}",
                            "-runs=1" if stage == "seed" else f"-max_total_time={max_total_time}",
                        ]
                        run(
                            [
                                "cargo",
                                "fuzz",
                                "run",
                                "--sanitizer=none",
                                "roc-fuzz",
                                str(corpus),
                                "--",
                                *libfuzzer_args,
                            ],
                            env=cargo_archive_environment(archive, environment),
                            verbose=verbose or stage == "fuzz",
                        )
                        print(f"PASS {stage}: {target['name']}")

                verify_failure_artifact(
                    roc=roc,
                    suite_root=suite_root,
                    bundle_url=bundle_url,
                    environment=environment,
                    verbose=verbose,
                )

            expected_request = f"/{urllib.parse.quote(bundle.name)}"
            if expected_request not in requests:
                raise TestFailure("Roc did not fetch the platform from the local bundle server")


def main() -> None:
    parser = argparse.ArgumentParser(description="Run the roc-fuzz spec matrix")
    parser.add_argument(
        "--operation",
        choices=("all", "validate", "build", "seed", "fuzz"),
        default="validate",
    )
    parser.add_argument("--target", action="append", dest="targets")
    parser.add_argument("--roc", default=os.environ.get("ROC", "roc"))
    parser.add_argument("--max-total-time", type=int, default=5)
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args()
    if args.max_total_time < 1:
        raise TestFailure("--max-total-time must be at least one second")

    defaults, all_targets, retired = load_spec()
    targets = select_targets(all_targets, args.targets)
    roc, version, _pinned = resolve_compiler(args.roc)
    print(f"Using {version}")
    print(f"Spec: {len(all_targets)} active targets, {len(retired)} retired targets")

    selected_stages = {
        "validate": {"fmt", "check", "test"},
        "build": {"build"},
        "seed": {"seed"},
        "fuzz": {"fuzz"},
        "all": {"fmt", *STAGES},
    }[args.operation]

    if "fmt" in selected_stages:
        roc_files = [
            "platform/main.roc",
            "platform/Arbitrary.roc",
            "platform/tests/failureArtifact.roc",
            *[str(item["path"]) for item in all_targets],
        ]
        run([roc, "fmt", "--check", *roc_files], verbose=args.verbose)
        print("PASS fmt")

    consumer_stages = selected_stages - {"fmt"}
    if consumer_stages:
        run_consumer_stages(
            defaults=defaults,
            targets=targets,
            selected_stages=consumer_stages,
            roc=roc,
            verbose=args.verbose,
            max_total_time=args.max_total_time,
        )


if __name__ == "__main__":
    try:
        main()
    except TestFailure as error:
        raise SystemExit(str(error)) from error
