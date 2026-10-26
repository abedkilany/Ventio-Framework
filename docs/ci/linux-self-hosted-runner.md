# Linux self-hosted runner for the Host Engineering Gate

The Linux Host audit needs to launch selected subprocesses as UID `65534`
(`nobody`) while the runner itself remains the dedicated, unprivileged
`actions` account. Do not run the runner as root and do not grant the runner
general passwordless `sudo` access.

The reviewed helper in `scripts/ci/ventio-ci-drop-to-nobody.py` is installed
outside the checkout at `/usr/local/libexec/ventio-ci-drop-to-nobody`, owned by
`root:root` and mode `0755`. A sudoers rule permits only this helper, with no
command-line arguments. The helper verifies the invoking runner account,
accepts a bounded JSON request on stdin, and permits only the audit's UID probe,
filesystem-boundary Python check, and compiled Host launcher. It drops to
UID `65534` and the runner's read-only witness group before executing any
request-supplied command or environment. No repository code runs as root.

For this runner installation, `actions` must remain UID/GID `1001`; if the
dedicated account is recreated with different IDs, update and review the helper
before installing it. Copy the reviewed helper to a root-owned path; never run
the checkout copy through `sudo`.

For the prepared VM setup, place the reviewed helper at
`/home/ventio/ventio-ci-drop-to-nobody.py` and the installer script at
`/home/ventio/install-ventio-ci-drop-helper.sh`, then run the installer as
`ventio` (without prefixing the script with `sudo`). It invokes only the
specific `sudo install`, `sudo tee`, `sudo chmod`, and `sudo visudo` commands
needed to install the helper and the restricted rule.

The one-time sudoers entry is:

```sudoers
actions ALL=(root) NOPASSWD: /usr/local/libexec/ventio-ci-drop-to-nobody ""
```

Validate the installed file with `visudo -c`. Verify the allowance and the
identity transition with `sudo -l -U actions` and a stdin request for `id -u`;
the latter must print `65534`. The workflow runs unit tests for the helper's
allowlist before the Host audit.
