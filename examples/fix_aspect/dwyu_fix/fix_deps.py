"""
Apply the findings of a DWYU report to the BUILD file of the analyzed target
with buildozer.
"""

import fcntl
import json
import logging
import os
import re
import subprocess
import sys
from argparse import ArgumentParser, Namespace
from collections import defaultdict
from pathlib import Path
from typing import TextIO

from python.runfiles import Runfiles

logging.basicConfig(format="%(message)s", level=logging.INFO)
log = logging.getLogger()

BUILDOZER = Runfiles.Create().Rlocation("buildozer_binary/buildozer.exe")
# https://github.com/bazel-contrib/buildtools/blob/main/buildozer/README.md#error-code
BUILDOZER_SUCCESS = 0
BUILDOZER_NO_CHANGES = 3
BUILDOZER_SUCCESS_CODES = (BUILDOZER_SUCCESS, BUILDOZER_NO_CHANGES)


def cli() -> Namespace:
    parser = ArgumentParser()
    parser.add_argument("report", type=Path, help="DWYU report of the target")
    parser.add_argument(
        "header_owners",
        type=Path,
        help="File with a '<header> <owner>' line for each header in the dependency closure of the target",
    )
    return parser.parse_args()


def apparent_label(label: str) -> str:
    """
    Transform a canonical label into an apparent label usable in a BUILD file of
    the main repository.

    This is a simplification: a real mapping would need to be passed in for
    external repos.
    """
    repo, _, rest = label.partition("//")
    repo = repo.removeprefix("@@").removeprefix("@")
    if not repo:
        return f"//{rest}"
    apparent_repo = [component for component in re.split("[+~]", repo) if component][-1]
    return f"@{apparent_repo}//{rest}"


class HeaderOwners:
    """
    Owning target of each header in the dependency closure, read from '<header> <owner>' lines.
    """

    def __init__(self, lines: TextIO) -> None:
        self._owners = defaultdict(set)
        for line in lines:
            header, owner = line.rstrip("\n").split(" ", 1)
            self._owners[header].add(owner)

    def lookup(self, header: str) -> str:
        owners = self._owners.get(header, set())
        if not owners:
            raise LookupError(f"unable to find owner for '{header}'")
        if len(owners) > 1:
            raise LookupError(f"multiple owners for '{header}': {', '.join(sorted(owners))}")
        return next(iter(owners))


def buildozer_tasks(report: dict, header_owners: HeaderOwners) -> tuple[list[str], list[str]]:
    """
    Returns the buildozer tasks and the errors for headers without a unique owner.
    """
    add = set()
    errors = []

    for key in ("public_includes_without_dep", "private_includes_without_dep"):
        for headers in report[key].values():
            for header in headers:
                try:
                    add.add(apparent_label(header_owners.lookup(header)))
                except LookupError as error:
                    errors.append(str(error))

    remove = [apparent_label(dep) for dep in report["unused_deps"]]

    tasks = []
    if add:
        tasks.append(f"add deps {' '.join(sorted(add))}")
    if remove:
        tasks.append(f"remove deps {' '.join(remove)}")

    return tasks, errors


def main(args: Namespace) -> int:
    report = json.loads(args.report.read_text(encoding="utf-8"))

    target = apparent_label(report["analyzed_target"])

    with args.header_owners.open(encoding="utf-8") as lines:
        tasks, errors = buildozer_tasks(report, HeaderOwners(lines))

    for error in errors:
        log.error(error)

    if tasks:
        package_dir = Path(target.removeprefix("//").split(":", 1)[0])
        build_file = package_dir / "BUILD.bazel"
        if not build_file.exists():
            build_file = package_dir / "BUILD"
        lock_fd = os.open(build_file, os.O_RDONLY)
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        for task in tasks:
            command = [BUILDOZER, task, target]
            process = subprocess.run(command, check=False, capture_output=True, text=True)
            if process.returncode not in BUILDOZER_SUCCESS_CODES:
                log.error(f"Buildozer command {command} failed:\n{process.stderr}")
                return 1

    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(cli()))
