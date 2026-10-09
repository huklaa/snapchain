#!/bin/bash

# Run with: bash scripts/snapchain-autoupgrade-test.sh
# Exercises the full autoupgrade command with no Docker, network, sudo or cron
# operations. Each case has a temporary HOME and a minimal cron environment.
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/snapchain.sh"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
FAILURES=0
TESTS=0

check() {
    TESTS=$((TESTS + 1))
    local description="$1"
    shift
    if "$@"; then
        echo "ok   - $description"
    else
        echo "FAIL - $description"
        FAILURES=$((FAILURES + 1))
    fi
}

path_includes() { [[ ":$observed_path:" == *":$1:"* ]]; }

# Functions take precedence over PATH, including after the script installs its
# baseline PATH. This keeps stubs in effect even on hosts with Docker installed.
cat > "$ROOT/stubs.sh" <<'STUBS'
uname() { echo Linux; }
id() { echo 0; }
jq() { :; }
docker() { printf 'docker %s\n' "$*" >> "$HOME/calls"; }
docker-compose() {
    printf 'compose %s\n' "$*" >> "$HOME/calls"
    printf '%s\n' "$PATH" > "$HOME/observed-path"
    command -v operator-tool > "$HOME/observed-tool" || :
    if [[ "$*" == "ps statsd" ]]; then echo Up; fi
}
curl() {
    while (( $# )); do
        if [[ "$1" == "-o" ]]; then : > "$2"; return 0; fi
        shift
    done
    echo 'Unexpected curl arguments' >&2
    exit 99
}
sudo() { echo 'Unexpected sudo invocation' >&2; exit 99; }
sleep() { :; }
STUBS

for scenario in missing existing early-return custom-path; do
    scenario_home="$ROOT/$scenario"
    mkdir -p "$scenario_home/snapchain" "$scenario_home/bin"
    printf '#!/bin/bash\nexit 0\n' > "$scenario_home/bin/operator-tool"
    chmod +x "$scenario_home/bin/operator-tool"
    printf 'AGREE_NO_REWARDS_FOR_ME=true\nSKIP_SELF_UPGRADE=true\n' > "$scenario_home/snapchain/.env"
    case "$scenario" in
        existing)
            printf 'export PATH="$HOME/bin:$PATH"\nprintf loaded > "$HOME/bashrc-loaded"\n' > "$scenario_home/.bashrc"
            ;;
        early-return)
            printf 'case $- in *i*) ;; *) return ;; esac\n' > "$scenario_home/.bashrc"
            ;;
    esac
    initial_path=/usr/bin:/bin
    if [[ "$scenario" == custom-path ]]; then initial_path="$scenario_home/bin:$initial_path"; fi
    rc=0
    output="$(cd "$scenario_home/snapchain" && env -i HOME="$scenario_home" PATH="$initial_path" \
        BASH_ENV="$ROOT/stubs.sh" /bin/bash "$SCRIPT" autoupgrade 2>&1)" || rc=$?
    check "$scenario: successful exit" test "$rc" -eq 0
    check "$scenario: completed autoupgrade" grep -q 'Completed snapchain autoupgrade' <<< "$output"
    check "$scenario: no missing bashrc error" test "${output#*No such file or directory}" = "$output"
    observed_path="$(cat "$scenario_home/observed-path")"
    for directory in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
        check "$scenario: PATH includes $directory" path_includes "$directory"
    done
    check "$scenario: service restart intercepted" grep -qx 'compose up -d snapchain' "$scenario_home/calls"
    if [[ "$scenario" == existing ]]; then
        check "$scenario: bashrc loaded" test -f "$scenario_home/bashrc-loaded"
    fi
    if [[ "$scenario" == existing || "$scenario" == custom-path ]]; then
        check "$scenario: custom tool remains available" grep -qx "$scenario_home/bin/operator-tool" "$scenario_home/observed-tool"
    fi
done

echo "$((TESTS - FAILURES))/$TESTS checks passed"
test "$FAILURES" -eq 0
