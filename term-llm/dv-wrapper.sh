#!/usr/bin/env bash
#
# second-brain dv wrapper — installed in a term-llm agent's PATH (as `dv`) so a bare
# `dv …` transparently forwards to the REAL dv on the remote dev box, over the SSH
# alias whose key is locked to `dv` and nothing else by term-llm/dv-ssh-guard.py.
#
# Why it exists: the bot's model tends to run `dv …` directly in its own shell
# (where there's no dv) instead of the explicit `ssh <alias> -- dv …` the skill
# teaches — so it just reports "command not found" and never reaches the dev box.
# This shim makes the natural `dv …` invocation Just Work, with no reliance on the
# model activating the skill. The guard still constrains it to dv-only, so there is
# no privilege change.
#
# The alias and home placeholders below are substituted at install time by
# scripts/setup-dv-for-agent.sh (sed). Don't run this copy directly.
#
# Argument safety: we DON'T do `ssh <alias> -- dv "$@"`, because ssh re-joins the
# remote command with spaces and a model-parsed quoted group (e.g. `-- bash -lc
# 'a && b'`) or an arg containing spaces would lose its quoting and be mis-split by
# the guard's shlex.split. Instead we build ONE command string in which every arg is
# POSIX single-quoted, and hand that to ssh as a single argument — so shlex.split on
# the far side reconstructs argv exactly, quoted groups and spaces intact.

export HOME=@HOME@

remote=dv
for a in "$@"; do
  esc=${a//\'/\'\\\'\'}   # ' -> '\''  (POSIX single-quote escaping)
  remote="$remote '$esc'"
done

# -o LogLevel=ERROR keeps ssh's own notices (e.g. "Warning: Permanently added … to
# known hosts" from accept-new) off stderr, so they never leak into chat.
exec ssh -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR @ALIAS@ -- "$remote"
