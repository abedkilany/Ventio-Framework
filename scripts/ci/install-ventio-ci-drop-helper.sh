#!/usr/bin/env bash
set -euo pipefail

source_helper=/home/ventio/ventio-ci-drop-to-nobody.py
installed_helper=/usr/local/libexec/ventio-ci-drop-to-nobody
sudoers_candidate=/tmp/ventio-ci-drop-to-nobody.sudoers
sudoers_installed=/etc/sudoers.d/ventio-ci-drop-to-nobody

test "$(id -u actions)" = 1001
test "$(id -g actions)" = 1001
test -f "$source_helper"

# Install the fixed helper as data. Never execute the checkout copy as root.
sudo install -d -o root -g root -m 0755 /usr/local/libexec
sudo install -o root -g root -m 0755 "$source_helper" "$installed_helper"
printf '%s\n' 'actions ALL=(root) NOPASSWD: /usr/local/libexec/ventio-ci-drop-to-nobody ""' \
  | sudo tee "$sudoers_candidate" >/dev/null
sudo chmod 0440 "$sudoers_candidate"
sudo visudo -cf "$sudoers_candidate"
sudo install -o root -g root -m 0440 "$sudoers_candidate" "$sudoers_installed"
sudo visudo -c
sudo rm -f "$sudoers_candidate"
sudo -l -U actions
printf '%s\n' 'VENTIO_CI_HELPER_INSTALLED'
