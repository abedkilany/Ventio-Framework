#!/usr/bin/env bash
set -euo pipefail

source_helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ventio-ci-drop-to-nobody.py"
installed_helper=/usr/local/libexec/ventio-ci-drop-to-nobody
sudoers_candidate=/tmp/ventio-ci-drop-to-nobody.sudoers
sudoers_installed=/etc/sudoers.d/ventio-ci-drop-to-nobody

# GitHub-hosted Ubuntu runners use the dedicated `runner` account with UID 1001.
test "$(id -un)" = runner
test "$(id -u runner)" = 1001
test -f "$source_helper"

# Some hosted images create this root-owned include with an overly broad mode.
# Tighten only that known include before global visudo validation; never ignore a
# failed validation or relax sudoers permissions to make the audit run.
if sudo test -e /etc/sudoers.d/runner; then
  sudo test ! -L /etc/sudoers.d/runner
  test "$(sudo stat -c %u /etc/sudoers.d/runner)" = 0
  sudo stat -c 'Hosted runner sudoers before: %u:%g %a %n' /etc/sudoers.d/runner
  sudo chmod 0440 /etc/sudoers.d/runner
fi

# Install reviewed checkout code as data. Never execute the checkout copy as root.
sudo install -d -o root -g root -m 0755 /usr/local/libexec
sudo install -o root -g root -m 0755 "$source_helper" "$installed_helper"
printf '%s\n' 'runner ALL=(root) NOPASSWD: /usr/local/libexec/ventio-ci-drop-to-nobody ""' \
  | sudo tee "$sudoers_candidate" >/dev/null
sudo chmod 0440 "$sudoers_candidate"
sudo visudo -cf "$sudoers_candidate"
sudo install -o root -g root -m 0440 "$sudoers_candidate" "$sudoers_installed"
sudo visudo -c
sudo rm -f "$sudoers_candidate"
sudo -l -U runner
printf '%s\n' 'VENTIO_CI_HELPER_INSTALLED'
