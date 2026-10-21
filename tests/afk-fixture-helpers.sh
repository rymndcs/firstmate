#!/usr/bin/env bash
# Shared safety boundary for the Desktop away fixtures and mutation runs.
fm_afk_fixture_prepare() {
  local name
  while IFS= read -r name; do
    case "$name" in
      HERDR*|TMUX*|CMUX*|ZELLIJ*|ORCA*|FM_SUPERVISOR*|FM_BACKEND*|FM_HOME|FM_ROOT*|FM_STATE_*|FM_CONFIG_*|__CFBundleIdentifier)
        unset "$name" ;;
    esac
  done < <(compgen -e)
}

fm_afk_fixture_probe() {
  compgen -e
  printf 'fixture-probe-complete\n'
}

fm_afk_fixture_install() {  # <copied-project>
  local project=$1 cli tools
  tools="$project/fixture-tools"
  mkdir -p "$tools"
  cat > "$tools/terminal.sh" <<'SH'
fm_afk_fake_terminal() {
  printf '%s\n' "$1" >> "${FM_HOME:?}/state/fake-backend.calls"
  return 1
}
tmux() { fm_afk_fake_terminal tmux "$@"; }
herdr() { fm_afk_fake_terminal herdr "$@"; }
cmux() { fm_afk_fake_terminal cmux "$@"; }
zellij() { fm_afk_fake_terminal zellij "$@"; }
orca() { fm_afk_fake_terminal orca "$@"; }
SH
  for cli in tmux herdr cmux zellij orca; do
    cat > "$tools/$cli" <<'SH'
#!/usr/bin/env bash
. "$(dirname "$0")/terminal.sh"
fm_afk_fake_terminal "$(basename "$0")" "$@"
SH
    chmod +x "$tools/$cli"
  done
  # Source fake commands inside copied Bash code as well as through PATH, so a
  # child login shell changing PATH cannot expose a real terminal transport.
  printf '\n. %q\n' "$tools/terminal.sh" >> "$project/bin/fm-backend.sh"
  export PATH="$tools:$PATH"
}

fm_afk_fixture_coordinator() {  # <fixture-home>, with shortened durations in env
  python3 - "$1" <<'PY'
import os,signal,subprocess,sys
from pathlib import Path
home=Path(sys.argv[1])
p=subprocess.Popen([str(home/'bin/fm-supervise-daemon.sh'),'--stop-hook'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
try:
    try:out,err=p.communicate(timeout=float(os.environ.get('FM_AFK_FIXTURE_TIMEOUT_SECS','3')))
    except subprocess.TimeoutExpired:
        os.killpg(p.pid,signal.SIGTERM)
        try:p.communicate(timeout=1)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid,signal.SIGKILL);p.communicate(timeout=1)
        raise AssertionError('coordinator did not retire within the shortened fixture bound')
    assert p.returncode==0, f'fixture coordinator failed: {err}'
    sys.stdout.write(out)
finally:
    if p.poll() is None:
        os.killpg(p.pid,signal.SIGKILL);p.wait()
PY
}
