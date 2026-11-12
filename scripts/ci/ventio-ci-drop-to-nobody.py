#!/usr/bin/python3 -I
"""Narrow root-owned helper for the Linux host engineering audit.

This helper is installed outside the runner checkout and granted through a
single sudoers entry. It accepts a command and its environment on stdin, drops
all root privileges before executing anything supplied by the runner, and
never executes repository code as root.
"""

import json
import os
import sys


RUNNER_UID = "1001"
RUNNER_NAME = "runner"
TARGET_UID = 65534
MAX_REQUEST_BYTES = 1_048_576
ALLOWED_PROGRAMS = {
    "id": "/usr/bin/id",
    "python3": "/usr/bin/python3",
    "/usr/bin/id": "/usr/bin/id",
    "/usr/bin/python3": "/usr/bin/python3",
    "/tmp/ventio-audit-host": "/tmp/ventio-audit-host",
}


def fail(message: str) -> "NoReturn":
    print(f"ventio-ci-drop-to-nobody: {message}", file=sys.stderr)
    raise SystemExit(126)


def validated_request(payload: object) -> tuple[str, list[str], dict[str, str]]:
    """Validate the unprivileged child request before dropping privileges."""
    if not isinstance(payload, dict) or set(payload) != {"command", "environment"}:
        fail("request must be a JSON object")
    command = payload.get("command")
    environment = payload.get("environment")
    if (
        not isinstance(command, list)
        or not command
        or any(not isinstance(arg, str) or "\0" in arg for arg in command)
    ):
        fail("command must be a non-empty string array")
    if not isinstance(environment, dict) or any(
        not isinstance(key, str)
        or not isinstance(value, str)
        or "\0" in key
        or "\0" in value
        for key, value in environment.items()
    ):
        fail("environment must contain only string keys and values")

    program = ALLOWED_PROGRAMS.get(command[0])
    if program is None:
        fail("program is not allowed")
    arguments = [program, *command[1:]]
    if program == "/usr/bin/id" and arguments[1:] != ["-u"]:
        fail("id is permitted only for the UID assertion")
    if program == "/tmp/ventio-audit-host" and len(arguments) != 1:
        fail("the audited Host launcher does not accept arguments")
    if program == "/usr/bin/python3" and (
        len(arguments) != 5 or arguments[1] != "-c"
    ):
        fail("python is permitted only for the filesystem boundary assertion")
    return program, arguments, environment


def main() -> None:
    if os.geteuid() != 0 or len(sys.argv) != 1:
        fail("must be invoked by sudo without command-line arguments")
    if (
        os.environ.get("SUDO_UID") != RUNNER_UID
        or os.environ.get("SUDO_USER") != RUNNER_NAME
    ):
        fail("caller is not the GitHub-hosted runner account")
    caller_gid = os.environ.get("SUDO_GID", "")
    if not caller_gid.isdecimal():
        fail("caller primary group is invalid")
    target_gid = int(caller_gid)

    request = sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1)
    if len(request) > MAX_REQUEST_BYTES:
        fail("request is too large")
    try:
        payload = json.loads(request)
    except (UnicodeDecodeError, json.JSONDecodeError):
        fail("request must be one JSON object")
    program, arguments, environment = validated_request(payload)

    # Keep the runner-owned read-only witness group, but perform the UID/GID
    # transition before executing commands or job-provided environment values.
    os.setgroups([target_gid])
    os.setgid(target_gid)
    os.setuid(TARGET_UID)
    os.execvpe(program, arguments, environment)


if __name__ == "__main__":
    main()
