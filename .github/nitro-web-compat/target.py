"""Bind the triggering run to an open PR using base-repository API data."""

import json
import os
import re
import subprocess


def target(run, pulls):
    sha = run["head_sha"]
    if not re.fullmatch("[0-9a-f]{40}", sha):
        raise ValueError("Invalid workflow run SHA")
    matches = [pr["number"] for pr in pulls
               if pr["state"] == "open" and pr["base"]["ref"] == "main"
               and pr["head"]["sha"] == sha and pr["head"]["ref"] == run["head_branch"]
               and (pr["head"]["repo"] or {}).get("id") == run["head_repository"]["id"]]
    if len(matches) == 1 and type(matches[0]) is int and matches[0] > 0:
        return matches[0]
    return None


if __name__ == "__main__":
    with open(os.environ["GITHUB_EVENT_PATH"]) as event:
        run = json.load(event)["workflow_run"]
    # Fork runs can have an empty workflow_run.pull_requests list.
    owner = run["head_repository"]["owner"]["login"]
    pulls = subprocess.check_output([
        "gh", "api", f"repos/{os.environ['GITHUB_REPOSITORY']}/pulls", "--method", "GET",
        "-f", "state=open", "-f", "base=main", "-f", f"head={owner}:{run['head_branch']}",
    ])
    number = target(run, json.loads(pulls))
    if number:
        print(f"sha={run['head_sha']}")
        print(f"number={number}")
