#!/usr/bin/env python3
"""Validate, build, seed, and smoke-test self-contained roc-fuzz targets."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import subprocess
import tempfile
from pathlib import Path

from platform_inputs import validate_platform_inputs


ROOT = Path(__file__).resolve().parents[1]
SPEC_PATH = ROOT / "scripts" / "test_spec.json"
CACHE = ROOT / ".test-cache" / "self-contained"
STAGES = ("check", "test", "build", "seed", "fuzz")
OPERATIONS = ("all", "validate", *STAGES)
REQUIRED_TARGET_KEYS = {"name", "path", "seed_hex", "libfuzzer_seed"}
OPTIONAL_TARGET_KEYS = {"expected_failure", "skip"}
GITHUB_ISSUE = re.compile(r"https://github\.com/[^/]+/[^/]+/issues/[1-9][0-9]*$")
SINGLE_FILE_COLLECTIONS = {"examples", "examples/builtins", "examples/sort"}


class TestFailure(RuntimeError):
    pass


def run(
    command: list[str],
    *,
    cwd: Path = ROOT,
    verbose: bool = False,
    capture: bool = False,
) -> subprocess.CompletedProcess[str]:
    if verbose:
        print("+", " ".join(command), flush=True)
    completed = subprocess.run(
        command,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    )
    if completed.returncode != 0:
        detail = f"\n{completed.stdout}" if capture and completed.stdout else ""
        raise TestFailure(
            f"command exited with {completed.returncode}: {' '.join(command)}{detail}"
        )
    return completed


def load_targets(selected: list[str]) -> list[dict[str, object]]:
    document = json.loads(SPEC_PATH.read_text(encoding="utf-8"))
    if set(document) != {"targets", "retired"}:
        raise TestFailure("test_spec.json must contain exactly targets and retired")

    targets = document["targets"]
    if not isinstance(targets, list) or not all(
        isinstance(target, dict) for target in targets
    ):
        raise TestFailure("targets must be an array of objects")

    for target in targets:
        keys = set(target)
        if not REQUIRED_TARGET_KEYS <= keys or keys - REQUIRED_TARGET_KEYS - OPTIONAL_TARGET_KEYS:
            raise TestFailure(
                "target must contain name, path, seed_hex, and libfuzzer_seed; "
                "only expected_failure and skip are optional"
            )
        name = target["name"]
        path = target["path"]
        seed_hex = target["seed_hex"]
        libfuzzer_seed = target["libfuzzer_seed"]
        if not isinstance(name, str) or not name:
            raise TestFailure("every target needs a non-empty name")
        if not isinstance(path, str):
            raise TestFailure(f"{name}: path must be a string")
        app_path = Path(path)
        expected_name = app_path.parent.name if app_path.name == "main.roc" else app_path.stem
        if name != expected_name:
            raise TestFailure(
                f"{name}: target name must match its file or app directory"
            )
        if not isinstance(seed_hex, str) or not seed_hex or len(seed_hex) % 2:
            raise TestFailure(f"{name}: seed_hex must be non-empty, even-length hex")
        try:
            bytes.fromhex(seed_hex)
        except ValueError as error:
            raise TestFailure(f"{name}: seed_hex is not valid hex") from error
        if not isinstance(libfuzzer_seed, int) or not 1 <= libfuzzer_seed <= 2_147_483_647:
            raise TestFailure(f"{name}: libfuzzer_seed must be a positive 32-bit integer")
        expected_failure = target.get("expected_failure", False)
        if not isinstance(expected_failure, bool):
            raise TestFailure(f"{name}: expected_failure must be a boolean")

        skip = target.get("skip", {})
        if not isinstance(skip, dict) or set(skip) - set(STAGES):
            raise TestFailure(f"{name}: skip keys must be test stages")
        for stage, explanation in skip.items():
            if not isinstance(explanation, dict) or set(explanation) != {
                "reason",
                "issue",
            }:
                raise TestFailure(
                    f"{name}: skipped {stage} must have exactly reason and issue"
                )
            reason = explanation["reason"]
            issue = explanation["issue"]
            if not isinstance(reason, str) or not reason.strip():
                raise TestFailure(f"{name}: skipped {stage} needs a reason")
            if not isinstance(issue, str) or not GITHUB_ISSUE.fullmatch(issue):
                raise TestFailure(
                    f"{name}: skipped {stage} needs a full GitHub issue URL"
                )
        if "build" in skip and not {"seed", "fuzz"} <= set(skip):
            raise TestFailure(f"{name}: skipping build also requires skipping seed and fuzz")
        if "seed" in skip and "fuzz" not in skip:
            raise TestFailure(f"{name}: skipping seed also requires skipping fuzz")

    names = [str(target["name"]) for target in targets]
    if len(names) != len(set(names)):
        raise TestFailure("test_spec.json contains duplicate target names")

    retired = document["retired"]
    if not isinstance(retired, list) or not all(
        isinstance(target, dict)
        and set(target) == {"name", "reason"}
        and isinstance(target["name"], str)
        and isinstance(target["reason"], str)
        and target["name"]
        and target["reason"]
        for target in retired
    ):
        raise TestFailure("retired targets need non-empty name and reason strings")
    retired_names = [str(target["name"]) for target in retired]
    if len(retired_names) != len(set(retired_names)) or set(retired_names) & set(names):
        raise TestFailure("active and retired target names must be unique")

    actual: set[str] = set()
    directories = {path.parent for path in (ROOT / "examples").rglob("*.roc")}
    for directory in directories:
        roc_sources = sorted(directory.glob("*.roc"))
        main = directory / "main.roc"
        relative = directory.relative_to(ROOT).as_posix()
        if len(roc_sources) > 1 and relative not in SINGLE_FILE_COLLECTIONS:
            if main not in roc_sources:
                raise TestFailure(
                    f"multi-file example {relative} must have main.roc as its app root"
                )
            actual.add(main.relative_to(ROOT).as_posix())
        else:
            actual.update(path.relative_to(ROOT).as_posix() for path in roc_sources)
    declared = {str(target["path"]) for target in targets}
    if actual != declared:
        missing = sorted(actual - declared)
        stale = sorted(declared - actual)
        raise TestFailure(f"target inventory mismatch; missing={missing}, stale={stale}")

    if not selected:
        return targets
    unknown = sorted(set(selected) - set(names))
    if unknown:
        raise TestFailure(f"unknown targets: {', '.join(unknown)}")
    wanted = set(selected)
    return [target for target in targets if target["name"] in wanted]


def targets_for_stage(
    targets: list[dict[str, object]], stage: str
) -> list[dict[str, object]]:
    active: list[dict[str, object]] = []
    for target in targets:
        skip = target.get("skip", {})
        assert isinstance(skip, dict)
        if stage in skip:
            explanation = skip[stage]
            assert isinstance(explanation, dict)
            print(
                f"SKIP {stage} {target['name']}: "
                f"{explanation['reason']} ({explanation['issue']})"
            )
        else:
            active.append(target)
    return active


def roc_files() -> list[Path]:
    return sorted(
        [
            *(ROOT / "examples").rglob("*.roc"),
            *(ROOT / "platform").glob("*.roc"),
        ]
    )


# Targets exempt from the allocation-assertion norm, each with a concrete
# reason. Keep this list short: a target that measures nothing about cost
# cannot catch an allocation regression, which is a whole class of bug that
# produces correct answers and so is invisible to a content property.
ALLOCATION_ASSERTION_EXEMPT = {
    "failureArtifact": "fixture whose whole purpose is to fail on a known input",
}

ALLOCATION_APIS = (
    "alloc_count!",
    "live_alloc_count!",
    "measure_allocs!",
    "expect_allocs_at_most!",
    "expect_no_leaks!",
)


def check_allocation_assertions(targets: list[dict[str, object]]) -> None:
    """Every target should assert on allocation behaviour, not only on results."""

    missing: list[str] = []
    for target in targets:
        name = str(target["name"])
        if name in ALLOCATION_ASSERTION_EXEMPT:
            continue
        source = (ROOT / str(target["path"])).read_text(encoding="utf-8")
        if not any(api in source for api in ALLOCATION_APIS):
            missing.append(f"{name} ({target['path']})")
    if missing:
        listed = "\n  ".join(missing)
        raise SystemExit(
            "these targets assert nothing about allocations:\n  "
            + listed
            + "\n\nUse one of "
            + ", ".join(f"Fuzz.{api}" for api in ALLOCATION_APIS)
            + " to pin the cost of the operation under test, or add the target to"
            + " ALLOCATION_ASSERTION_EXEMPT in scripts/test.py with a concrete reason."
        )


def check_targets(roc: str, targets: list[dict[str, object]], verbose: bool) -> None:
    run([roc, "fmt", "--check", *map(str, roc_files())], verbose=verbose)
    for target in targets:
        run([roc, "check", str(ROOT / str(target["path"]))], verbose=verbose)
    check_allocation_assertions(targets)


def test_targets(roc: str, targets: list[dict[str, object]], verbose: bool) -> None:
    for target in targets:
        run([roc, "test", str(ROOT / str(target["path"]))], verbose=verbose)


def build_target(roc: str, target: dict[str, object], verbose: bool) -> Path:
    output_dir = CACHE / "executables"
    output_dir.mkdir(parents=True, exist_ok=True)
    output = output_dir / str(target["name"])
    run(
        [
            roc,
            "build",
            "--fuzz",
            str(ROOT / str(target["path"])),
            f"--output={output}",
        ],
        verbose=verbose,
    )
    validate_executable(output)
    return output


def validate_executable(output: Path) -> None:
    description = subprocess.check_output(["file", str(output)], text=True).strip()
    system = platform.system()
    if system == "Linux":
        if output.read_bytes()[:4] != b"\x7fELF":
            raise TestFailure(f"{output} is not an ELF executable")
        if "statically linked" not in description or "x86-64" not in description:
            raise TestFailure(f"unexpected executable format: {description}")
        return
    if system == "Darwin":
        if output.read_bytes()[:4] != b"\xcf\xfa\xed\xfe":
            raise TestFailure(f"{output} is not a 64-bit Mach-O executable")
        if "Mach-O 64-bit executable arm64" not in description:
            raise TestFailure(f"unexpected executable format: {description}")
        validate_macos_deployment_target(output)
        dependencies = subprocess.check_output(["otool", "-L", str(output)], text=True).splitlines()[1:]
        non_system = [line.strip().split(" ", 1)[0] for line in dependencies if line.strip() and not line.lstrip().startswith(("/usr/lib/", "/System/Library/"))]
        if non_system:
            raise TestFailure(
                f"{output} has non-system dynamic dependencies: {', '.join(non_system)}"
            )
        return
    raise TestFailure(f"unsupported host platform for executable validation: {system}")


def validate_macos_deployment_target(output: Path) -> None:
    lines = subprocess.check_output(["otool", "-l", str(output)], text=True).splitlines()
    for start, line in enumerate(lines):
        if line.strip() != "cmd LC_BUILD_VERSION":
            continue
        for candidate in lines[start + 1 : start + 8]:
            match = re.fullmatch(r"\s*minos (\d+)\.(\d+)(?:\.\d+)?\s*", candidate)
            if match is None:
                continue
            minimum = (int(match.group(1)), int(match.group(2)))
            if minimum != (11, 0):
                raise TestFailure(
                    f"unexpected macOS deployment target for {output}: "
                    f"{match.group(1)}.{match.group(2)} (expected 11.0)"
                )
            return
        raise TestFailure(f"LC_BUILD_VERSION has no parseable minimum target in {output}")
    raise TestFailure(f"{output} is missing LC_BUILD_VERSION")


def build_targets(
    roc: str, targets: list[dict[str, object]], verbose: bool
) -> dict[str, Path]:
    if not targets:
        return {}
    try:
        validate_platform_inputs(ROOT)
    except RuntimeError as error:
        raise TestFailure(str(error)) from error
    return {
        str(target["name"]): build_target(roc, target, verbose) for target in targets
    }


def seed_path(target: dict[str, object]) -> Path:
    corpus = CACHE / "corpus" / str(target["name"])
    corpus.mkdir(parents=True, exist_ok=True)
    path = corpus / "seed"
    path.write_bytes(bytes.fromhex(str(target["seed_hex"])))
    return path


def replay_seeds(
    executables: dict[str, Path],
    targets: list[dict[str, object]],
    verbose: bool,
) -> None:
    for target in targets:
        executable = executables[str(target["name"])]
        seed = seed_path(target)
        run([str(executable), "show", str(seed)], verbose=verbose, capture=not verbose)
        replay = [str(executable), "replay", str(seed)]
        if target.get("expected_failure", False):
            CACHE.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix="replay-", dir=CACHE) as temp:
                if verbose:
                    print("+", " ".join(replay), "# expected failure", flush=True)
                completed = subprocess.run(
                    replay,
                    cwd=temp,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                )
            if completed.returncode != 77:
                raise TestFailure(
                    f"expected replay failure from {target['name']}, got "
                    f"{completed.returncode}\n{completed.stdout}"
                )
        else:
            run(replay, verbose=verbose, capture=not verbose)


def fuzz_targets(
    executables: dict[str, Path],
    targets: list[dict[str, object]],
    seconds: int,
    verbose: bool,
) -> None:
    for target in targets:
        executable = executables[str(target["name"])]
        if target.get("expected_failure", False):
            verify_failure_artifact(executable, target, verbose)
            continue
        seed = seed_path(target)
        corpus = seed.parent
        run(
            [
                str(executable),
                "run",
                str(corpus),
                f"--time={seconds}",
                "--max-input-size=4096",
                f"--seed={target['libfuzzer_seed']}",
            ],
            verbose=verbose,
            capture=not verbose,
        )


def verify_failure_artifact(
    executable: Path, target: dict[str, object], verbose: bool
) -> None:
    CACHE.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="failure-", dir=CACHE) as temp:
        work = Path(temp)
        corpus = work / "corpus"
        corpus.mkdir()
        seed = corpus / "reproducer"
        seed.write_bytes(bytes.fromhex(str(target["seed_hex"])))
        artifact = work / ".roc-fuzz" / (
            "crash-" + hashlib.sha1(seed.read_bytes()).hexdigest()
        )

        completed = subprocess.run(
            [str(executable), "run", str(corpus), "--runs=10"],
            cwd=work,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        if completed.returncode != 77:
            raise TestFailure(
                f"failure target exited with {completed.returncode}\n{completed.stdout}"
            )
        if not artifact.is_file() or artifact.read_bytes() != seed.read_bytes():
            raise TestFailure("libFuzzer did not save the exact reproducing input")
        for command in (" show ", " replay ", " minimize "):
            if command not in completed.stdout:
                raise TestFailure(
                    f"failure output did not suggest {command.strip()}"
                )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--operation", choices=OPERATIONS, default="all")
    parser.add_argument("--target", action="append", default=[])
    parser.add_argument("--max-total-time", type=int, default=2)
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args()

    if args.max_total_time < 1:
        raise SystemExit("--max-total-time must be at least one second")

    roc = os.environ.get("ROC", "roc")
    try:
        targets = load_targets(args.target)
        if args.operation in ("all", "validate", "check"):
            check_targets(roc, targets_for_stage(targets, "check"), args.verbose)
        if args.operation in ("all", "validate", "test"):
            test_targets(roc, targets_for_stage(targets, "test"), args.verbose)

        if args.operation == "all":
            buildable = targets_for_stage(targets, "build")
            executables = build_targets(roc, buildable, args.verbose)
            replay_seeds(
                executables,
                targets_for_stage(targets, "seed"),
                args.verbose,
            )
            fuzz_targets(
                executables,
                targets_for_stage(targets, "fuzz"),
                args.max_total_time,
                args.verbose,
            )
        elif args.operation in ("build", "seed", "fuzz"):
            stage_targets = targets_for_stage(targets, args.operation)
            executables = build_targets(roc, stage_targets, args.verbose)
            if args.operation in ("seed", "fuzz"):
                replay_seeds(executables, stage_targets, args.verbose)
            if args.operation == "fuzz":
                fuzz_targets(
                    executables,
                    stage_targets,
                    args.max_total_time,
                    args.verbose,
                )
    except (OSError, subprocess.CalledProcessError, TestFailure) as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
