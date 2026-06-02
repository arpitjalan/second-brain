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

Setup on the dev machine (after installing dv + Docker):

    curl -fsSL <repo>/term-llm/dv-ssh-guard.py -o dv-ssh-guard.py
    python3 dv-ssh-guard.py --install "ssh-ed25519 AAAA… stan-dv"

Why injection-safe: $SSH_ORIGINAL_COMMAND is parsed with shlex.split (shell-like
*parsing*, never *execution*) and handed to os.execv — no shell runs, so $(...),
backticks, ;, |, && in the raw string are never interpreted. A quoted group like
`dv run --name x -- bash -lc 'cd /var/www/discourse && bin/rspec'` survives as a
single argument to dv.
"""

import os
import shlex
import shutil
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
    os.environ["PATH"] = os.pathsep.join(COMMON_BIN + [os.environ.get("PATH", "")])
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

    # 2) Add the locked authorized_keys entry (idempotent on the key body).
    ssh_dir = os.path.expanduser("~/.ssh")
    os.makedirs(ssh_dir, mode=0o700, exist_ok=True)
    ak = os.path.join(ssh_dir, "authorized_keys")
    key_body = (pubkey.split() + [""])[1] or pubkey
    existing = open(ak).read() if os.path.exists(ak) else ""
    if key_body in existing:
        sys.stderr.write("dv-ssh-guard: key already in authorized_keys; left as-is.\n")
    else:
        with open(ak, "a") as f:
            if existing and not existing.endswith("\n"):
                f.write("\n")
            f.write(f'restrict,command="{dest}" {pubkey}\n')
        os.chmod(ak, 0o600)
        sys.stderr.write(f"dv-ssh-guard: added dv-only key to {ak}\n")

    # 3) Print the client-side ssh config to paste on the term-llm server.
    dv = find_dv()
    print(f"\nGuard installed: {dest}")
    print(f"dv binary:       {dv or 'NOT FOUND — install dv before using this key'}")
    print("\nPaste into ~/.ssh/config on the term-llm server (edit HostName):\n")
    print("    Host dvhost")
    print(f"        HostName {os.uname().nodename}   # or this box's Tailscale/LAN address")
    print(f"        User {os.environ.get('USER', '<you>')}")
    print("        IdentityFile ~/.ssh/stan_dv_ed25519")
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
