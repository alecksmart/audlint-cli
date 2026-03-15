#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="${IMAGE:-fedora:41}"

declare -a DOCKER_TTY=()
if [[ -t 0 && -t 1 ]]; then
  DOCKER_TTY=(-it)
fi

exec docker run --rm "${DOCKER_TTY[@]}" \
  -v "${ROOT_DIR}:/work" \
  -w /work \
  "$IMAGE" \
  bash -lc '
    set -euo pipefail
    dnf install -y \
      bash cronie sqlite python3 python3-rich zip
    cd test
    python3 -m unittest -q \
      test_ui_regression.UiRegressionTests.test_filter_status_line_stays_well_formed \
      test_library_browser_smoke.LibraryBrowserSmokeTests.test_next_run_uses_managed_cron_schedule
    AUDLINT_USE_REAL_CRONTAB=1 python3 -m unittest -q \
      test_audlint_maintain_smoke.AudlintMaintainRealCrontabE2ETests.test_install_and_uninstall_cron_with_real_crontab
    cd ..
    env -u NO_COLOR TERM=xterm-256color ./bin/audlint.sh --no-interactive --db /tmp/library.sqlite --page-size 5
  '
