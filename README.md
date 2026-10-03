# Quant stack deploy

Component-selectable install/upgrade for Capture WAL daemons and tooling.

```text
/opt/quant/bin/{tape-capture,tape-sessionizer,quant,tape-lens,tape-verify}
/opt/quant/config/…
/var/lib/quant/{capture,sessions}
```

Systemd (Linux): template units `quant-tape-*@` — instances are enabled by
`quant -f … up -d`, not by the installer alone.

## Components

| Name | Binary |
|------|--------|
| `capture` | `tape-capture` |
| `sessionizer` | `tape-sessionizer` |
| `quant` | `quant` (+ unit templates) |
| `lens` | `tape-lens` |
| `verify` | `tape-verify` |
| `all` | everything above |

## Version channels

| Channel | Tags |
|---------|------|
| **stable** | `vX.Y.Z` |
| **pre-release** | `vX.Y.Z-devN` (`N` from 0 upward; higher = newer for that X.Y.Z) |

Default source is **git** (`QUANT_GIT_URL`, placeholder until set). Override with
`--source local` / `--bin-src` or `--source url` / `--url`.

On `--upgrade` (git): compares `$PREFIX/VERSION` to the latest tag on the same
channel. If not newer, prints that no new version is available and exits without
changing binaries.

## Private GitHub

For a private repo, set a fine-grained or classic PAT with **Contents: Read**
(and Metadata read if required by the org):

```bash
export QUANT_GIT_URL=https://github.com/ORG/REPO.git
export QUANT_GITHUB_TOKEN=ghp_…   # or GITHUB_TOKEN
# optional: chmod 600 /root/.config/quant.env && source it before install

sudo -E ./deploy/install.sh --components all --channel stable
```

The installer:

- injects the token into `https://github.com/…` for `git ls-remote` / clone (never logs the URL with credentials)
- sends `Authorization: Bearer` for GitHub release API + private asset downloads
- falls back to `cargo build` from the tagged checkout when no release asset exists

SSH remotes (`git@github.com:…`) are left unchanged — use a deploy key instead of a token.

## Install

```bash
# From a local release build
cargo build --release -p tape-capture -p tape-sessionizer -p quant -p tape-lens -p tape-verify
sudo ./deploy/install.sh --source local --bin-src ./target/release --components all --channel stable

# Default git path (needs network + tags on QUANT_GIT_URL)
sudo QUANT_GIT_URL=https://github.com/ORG/REPO.git \
  QUANT_GITHUB_TOKEN="$QUANT_GITHUB_TOKEN" \
  ./deploy/install.sh --components all --channel stable

# Pre-release channel
sudo ./deploy/install.sh --components all --channel pre-release

# Upgrade sessionizer + quant only if newer stable tag exists
sudo ./deploy/install.sh --upgrade --channel stable --components sessionizer,quant

# Dry-run
DRY_RUN=1 ./deploy/install.sh --source local --bin-src ./target/release \
  --components quant,lens --channel stable --dry-run
```

Env: `PREFIX` (default `/opt/quant`), `DATA_DIR` (default `/var/lib/quant`),
`QUANT_GIT_URL`, `QUANT_GITHUB_TOKEN` / `GITHUB_TOKEN`, `BIN_SRC`,
`ENABLE=1` + `--compose PATH` to run `quant up -d` after install.

Live configs are **never** overwritten; only `*.example.*` are refreshed.
Binary replace is atomic (`.new.$$` then `mv`).

After upgrading `sessionizer`, active sessionizer units are restarted by default
(`--no-restart-sessionizer` to skip). Capture restart requires `--restart-capture`.

## Uninstall

On a TTY with no flags, lists what is installed under `$PREFIX/bin` and asks
which to remove (numbers, comma-separated, or `a` for all). Then asks whether
to delete live configs and `$DATA_DIR` (default: keep).

```bash
# Interactive (pick installed apps)
sudo ./deploy/uninstall.sh

# Non-interactive / scripted
sudo ./deploy/uninstall.sh --components lens,verify
sudo ./deploy/uninstall.sh --components all
sudo REMOVE_DATA=1 REMOVE_CONFIG=1 ./deploy/uninstall.sh --components all
```

Non-TTY runs require `--components LIST|all`.

When installing `quant`, any leftover legacy fixed units (`tape-record.target`,
etc.) are disabled if still present. Prefer:

```bash
sudo -u quant /opt/quant/bin/quant -f /opt/quant/config/quant.yml up -d
```

## Signals / HA notes

| Signal | Behavior |
|--------|----------|
| `SIGTERM` | Clean stop (systemd default / `quant up` Ctrl-C) |
| Do not use `kill -9` for routine upgrades | |

Sessionizer upgrades are free relative to Capture WAL; capture restarts imply a
short venue gap until HA standby cutover exists.

## Deferred (phase 2)

- First-class boot-persistence / multi-instance enable UX polish
- Restart strategy knobs in `quant.yml`

## Self-test

```bash
./deploy/lib.sh --selftest
```
