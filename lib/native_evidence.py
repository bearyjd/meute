"""Record the runner's trusted selection before an opted-in engine dispatch."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import uuid
from pathlib import Path

CLAIM_VERSION = 1
RUN_ID = r"[0-9a-f]{32}"
CLAIM_FIELDS = {
    "version", "run_id", "source", "ref", "repo", "meute_task", "slot",
    "engine", "auth", "commit", "started_at",
}


def claim(
    state_dir: str, repo: str, task: str, slot: str, date: str, started: str,
    commit: str, engine: str, auth: str, product_task: str,
) -> tuple[str, str]:
    run_id = uuid.uuid4().hex
    # The report reference is published, so its nonce is independent of the run ID.
    ref = f"reports/{repo}/{task}-{date}.{uuid.uuid4().hex}.md"
    record: dict[str, str | int] = {
        "version": CLAIM_VERSION,
        "run_id": run_id,
        "source": "meute-runner",
        "ref": ref,
        "repo": repo,
        "meute_task": task,
        "slot": slot,
        "engine": engine,
        "auth": auth,
        "commit": commit,
        "started_at": started,
    }
    if product_task:
        record["task"] = product_task

    directory = Path(state_dir) / "evidence"
    directory.mkdir(mode=0o700, exist_ok=True)
    target = directory / f"{run_id}.json"
    with tempfile.NamedTemporaryFile(mode="w", dir=directory, encoding="utf-8") as temp:
        json.dump(record, temp)
        temp.write("\n")
        temp.flush()
        os.fsync(temp.fileno())
        os.link(temp.name, target)
    for parent in (directory, directory.parent):
        fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    return run_id, ref


if __name__ == "__main__":
    print(*claim(*sys.argv[1:]), sep="\t")
