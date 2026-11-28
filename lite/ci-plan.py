"""仅复用同一 PR 上已成功验证且输入未变化的任务；查询失败时重新验证。"""
import json
import os
import re
import subprocess

GROUPS = {
    "server": ("Lite / Linux x64 build and integration", (
        "lite/server", "lite/build-server.sh", "lite/test-server.sh")),
    "android": ("Lite / Android ARM64 compile", (
        "lite/android", "lite/prepare-android.py")),
}
WORKFLOW = ".github/workflows/server.yml"

def gh(path):
    return json.loads(subprocess.check_output(["gh", "api", path], text=True))

def workflow_inputs(revision, name):
    """比较工作流公共配置和该构建任务，其他任务的修改不触发重复编译。"""
    raw = subprocess.check_output(["git", "show", f"{revision}:{WORKFLOW}"], text=True)
    header, sep, jobs = raw.partition("\njobs:\n")
    if not sep:
        raise ValueError("Missing workflow jobs")
    match = re.search(r"(?ms)^  lite_" + re.escape(name) + r":\n.*?(?=^  [A-Za-z0-9_-]+:[ \t]*$|\Z)", jobs)
    if not match:
        raise ValueError("Missing build job")
    return header, match.group(0).rstrip()

def same_inputs(old, current, name, paths):
    result = subprocess.run(["git", "diff", "--quiet", old, current, "--", *paths])
    if result.returncode != 0:
        return False
    return workflow_inputs(old, name) == workflow_inputs(current, name)

def select():
    target = os.environ["TARGET"]
    required = {name: target in ("both", name) for name in GROUPS}
    pr = os.environ.get("PR_NUMBER")
    if not pr:
        return required
    repo = os.environ["GH_REPO"]
    current = os.environ["HEAD_SHA"]
    try:
        runs = gh(f"repos/{repo}/actions/workflows/server.yml/runs?event=pull_request&per_page=50")["workflow_runs"]
        for run in runs:
            if run["status"] != "completed" or run["head_sha"] == current:
                continue
            if not any(str(p["number"]) == pr for p in run.get("pull_requests", [])):
                continue
            old = run["head_sha"]
            candidates = [name for name, (_, paths) in GROUPS.items()
                          if required[name] and same_inputs(old, current, name, paths)]
            if not candidates:
                continue
            jobs = gh(f"repos/{repo}/actions/runs/{run['id']}/jobs?per_page=100")["jobs"]
            for name in candidates:
                if any(j["name"] == GROUPS[name][0] and j["conclusion"] == "success" for j in jobs):
                    required[name] = False
                    print(f"{name}: reuse validated inputs from run {run['id']}")
            if not any(required.values()):
                break
    except (KeyError, ValueError, subprocess.SubprocessError) as exc:
        print(f"Could not fully inspect prior runs: {type(exc).__name__}; unverified jobs still build")
    return required

if __name__ == "__main__":
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as out:
        for name, needed in select().items():
            print(f"{name}={str(needed).lower()}", file=out)
