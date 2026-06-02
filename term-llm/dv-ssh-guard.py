#!/usr/bin/env python3
"""SSH forced-command guard that permits ONLY `dv ...` — with one-shot install.

Two modes:

  • Forced command (normal use): reads $SSH_ORIGINAL_COMMAND, runs it only if it
    starts with `dv`, then execs dv directly — no shell, so it is injection-safe.
    The key can run any dv command (including commands *inside* dv's disposable
    Discourse containers, the sandbox) but nothing else on the host: no shell,
    no git/gh, no scp.

  • `--install "<bot public key>"`: sets itself up on the dev machine — copies
    itself to ~/.local/bin/dv-ssh-guard, adds a locked-down authorized_keys
    entry pointing at it, and prints the ~/.ssh/config block to paste on the
    term-llm server. Idempotent; run once.

Setup on the dev machine (Docker must already be installed AND running; then
install dv — its install.sh installs the dv binary only, NOT Docker):

    curl -fsSL <repo>/term-llm/dv-ssh-guard.py -o dv-ssh-guard.py
    python3 dv-ssh-guard.py --install "ssh-ed25519 AAAA… stan-dv"

Easier: run scripts/setup-dv.sh on the term-llm server — it scp's this file over
and runs --install for you, so you never touch the dev box by hand.

Why injection-safe: $SSH_ORIGINAL_COMMAND is parsed with shlex.split (shell-like
*parsing*, never *execution*) and handed to os.execv — no shell runs, so $(...),
backticks, ;, |, && in the raw string are never interpreted. A quoted group like
`dv run --name x -- bash -lc 'cd /var/www/discourse && bin/rspec'` survives as a
single argument to dv.
"""

import json
import os
import shlex
import shutil
import subprocess
import sys

# Where dv (and the docker it shells to) commonly live. SSH forced commands run
# with a minimal PATH, so we search these explicitly AND widen PATH before exec
# — otherwise dv-over-SSH fails to find dv/docker even when both are installed.
COMMON_BIN = [
    "/opt/homebrew/bin",
    "/usr/local/bin",
    os.path.expanduser("~/.local/bin"),
    "/usr/bin",
    "/bin",
]

# Restrict further by setting this to a set of allowed dv subcommands; None = all.
ALLOWED_SUBCOMMANDS = None


def deny(message):
    sys.stderr.write(f"dv-ssh-guard: {message}\n")
    sys.exit(1)


def find_dv():
    return shutil.which("dv") or next(
        (p for p in (os.path.join(d, "dv") for d in COMMON_BIN) if os.path.exists(p)),
        None,
    )


def detect_reach_hostname():
    """Best-effort address the term-llm server can reach this box at, for the
    printed ssh-config. Tailscale (the recommended transport) is stable and
    detectable; anything else this box can't know, so return a labelled placeholder
    rather than a misleading real hostname. Returns (host, how)."""
    ts = shutil.which("tailscale")
    if ts:
        try:
            r = subprocess.run(
                [ts, "status", "--json"], capture_output=True, text=True, timeout=5
            )
            if r.returncode == 0:
                data = json.loads(r.stdout)
                if data.get("BackendState") == "Running":
                    dns = (data.get("Self") or {}).get("DNSName", "").rstrip(".")
                    if dns:
                        return dns, "Tailscale MagicDNS (recommended)"
        except Exception:
            pass
        try:
            r = subprocess.run(
                [ts, "ip", "-4"], capture_output=True, text=True, timeout=5
            )
            ip = r.stdout.split("\n")[0].strip() if r.returncode == 0 else ""
            if ip:
                return ip, "Tailscale IP"
        except Exception:
            pass
    return "<dev-machine-address-the-server-can-reach>", "EDIT THIS — couldn't auto-detect"


def guard():
    raw = os.environ.get("SSH_ORIGINAL_COMMAND", "")
    if not raw.strip():
        deny("interactive sessions are not permitted; only `dv ...` commands.")
    try:
        argv = shlex.split(raw)
    except ValueError as exc:
        deny(f"could not parse command ({exc}).")
    if not argv or argv[0] != "dv":
        deny("only `dv` commands are permitted on this key.")
    if ALLOWED_SUBCOMMANDS is not None and (
        len(argv) < 2 or argv[1] not in ALLOWED_SUBCOMMANDS
    ):
        deny("that dv subcommand is not permitted on this key.")
    dv = find_dv()
    if not dv:
        deny("`dv` binary not found on this host (is dv installed?).")
    # Filter empty elements so a leading os.pathsep (which makes "" mean CWD — a
    # path-injection foothold) can't sneak in when PATH is unset.
    os.environ["PATH"] = os.pathsep.join(
        p for p in COMMON_BIN + [os.environ.get("PATH", "")] if p
    )
    os.execv(dv, [dv] + argv[1:])  # no shell; argv preserved


def install(pubkey):
    pubkey = pubkey.strip()
    if not pubkey.startswith(("ssh-", "ecdsa-", "sk-")):
        deny('argument to --install must be the bot\'s SSH *public* key string '
             '(e.g. "ssh-ed25519 AAAA… stan-dv").')

    src = os.path.abspath(__file__)
    if not os.path.isfile(src):
        deny("can't locate this script on disk — download it to a file first, "
             "then run `python3 dv-ssh-guard.py --install …` (don't pipe via stdin).")

    # 1) Install the guard to a stable, executable location.
    dest = os.path.expanduser("~/.local/bin/dv-ssh-guard")
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    if src != dest:
        shutil.copyfile(src, dest)
    os.chmod(dest, 0o755)

    # 2) Add/repair the locked authorized_keys entry. RECONCILE rather than skip:
    #    find any line carrying this key's blob and make it EXACTLY the restricted
    #    entry. So a re-run repairs a stale install path — and, crucially, rewrites a
    #    dangerous pre-existing UNRESTRICTED line for the same key — instead of
    #    reporting "left as-is" and leaving the wrong (over-permissive) thing in place.
    ssh_dir = os.path.expanduser("~/.ssh")
    os.makedirs(ssh_dir, exist_ok=True)
    ak = os.path.join(ssh_dir, "authorized_keys")
    parts = pubkey.split()
    key_blob = parts[1] if len(parts) >= 2 else pubkey  # the base64 body
    desired = f'restrict,command="{dest}" {pubkey}'
    if os.path.exists(ak):
        with open(ak, encoding="utf-8") as f:
            lines = f.read().splitlines()
    else:
        lines = []
    out, found, changed = [], False, False
    for line in lines:
        # Token-anchored match: the blob must appear as a whole whitespace token on
        # the line (not a substring), so one key body can't false-match another's.
        if key_blob in line.split():
            found = True
            if line.strip() != desired:
                out.append(desired)
                changed = True
            else:
                out.append(line)
        else:
            out.append(line)
    if not found:
        out.append(desired)
        changed = True
    if changed:
        with open(ak, "w", encoding="utf-8") as f:
            f.write("\n".join(out) + "\n")
        sys.stderr.write(f"dv-ssh-guard: wrote the dv-only key to {ak}\n")
    else:
        sys.stderr.write("dv-ssh-guard: dv-only key already correct in authorized_keys.\n")
    # ALWAYS enforce perms (not only on the write path): makedirs(mode=) is a no-op
    # on an existing dir, and sshd StrictModes silently ignores the key if ~/.ssh or
    # authorized_keys are group/other-writable.
    os.chmod(ssh_dir, 0o700)
    os.chmod(ak, 0o600)

    # 3) Print the client-side ssh config for the MANUAL path. (scripts/setup-dv.sh
    #    writes this for you and ignores this print.) This box can't know how the
    #    server routes to it, so detect Tailscale (the recommended transport) if
    #    present, else emit a clearly-labelled placeholder — never a real-looking
    #    nodename a user might paste verbatim and then silently fail to reach.
    dv = find_dv()
    host, how = detect_reach_hostname()
    print(f"\nGuard installed: {dest}")
    print(
        "dv binary:       "
        + (dv or "not on PATH now — the guard also searches ~/.local/bin etc. "
                 "at runtime; install dv if you haven't")
    )
    print("\nPaste into ~/.ssh/config on the term-llm server:\n")
    print("    Host dvhost")
    print(f"        HostName {host}   # {how}")
    print(f"        User {os.environ.get('USER', '<you>')}")
    print("        IdentityFile ~/.ssh/dvhost_ed25519")
    print("        IdentitiesOnly yes\n")
    print("Then verify from the term-llm server:  ssh dvhost -- dv version")


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "--install":
        if len(sys.argv) != 3:
            deny('usage: dv-ssh-guard.py --install "<bot public key>"')
        install(sys.argv[2])
    else:
        guard()


if __name__ == "__main__":
    main()
