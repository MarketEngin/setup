# Quant stack setup (installer)

Component-selectable install/upgrade. Downloads **per-app** GitHub Releases
from [`MarketEngin/MarketEngin`](https://github.com/MarketEngin/MarketEngin).

```text
/opt/quant/bin/{tape-capture,tape-sessionizer,quant,tape-lens,tape-verify}
/opt/quant/config/…
/var/lib/quant/{capture,sessions}
```

Systemd templates ship in this repo (`systemd/`). Instances are enabled by
`quant -f … up -d`, not by the installer alone.

## Components

| Name | Binary | Release tag | Asset |
|------|--------|-------------|-------|
| `capture` | `tape-capture` | `tape-capture-vX.Y.Z[-devN]` | `tape-capture-linux-amd64.tar.gz` |
| `sessionizer` | `tape-sessionizer` | `tape-sessionizer-v…` | `tape-sessionizer-linux-amd64.tar.gz` |
| `quant` | `quant` | `quant-v…` | `quant-linux-amd64.tar.gz` |
| `lens` | `tape-lens` | `tape-lens-v…` | `tape-lens-linux-amd64.tar.gz` |
| `verify` | `tape-verify` | `tape-verify-v…` | `tape-verify-linux-amd64.tar.gz` |
| `all` | everything above | | |

## Channels

| Channel | Tag shape |
|---------|-----------|
| **stable** | `{bin}-vX.Y.Z` |
| **pre-release** | `{bin}-vX.Y.Z-devN` |

Each component resolves its **own** latest tag on the channel and downloads that
release’s asset. `--upgrade` skips a component when the installed tag (from
`manifest.json`) is already ≥ latest.

## Private GitHub

```bash
export QUANT_GIT_URL=https://github.com/MarketEngin/MarketEngin.git
export QUANT_GITHUB_TOKEN=ghp_…   # Contents + metadata read (releases/assets)

sudo -E ./install.sh --components all --channel stable
sudo -E ./install.sh --components all --channel pre-release
```

## Install

```bash
# From GitHub Releases (default)
sudo -E ./install.sh --components all --channel stable

# Upgrade only components that have a newer tag
sudo -E ./install.sh --upgrade --channel stable --components sessionizer,quant

# Local binaries
sudo ./install.sh --source local --bin-src /path/to/bins --components quant,lens

# Dry-run
DRY_RUN=1 ./install.sh --components all --channel pre-release --dry-run
```

Env: `PREFIX` (`/opt/quant`), `DATA_DIR` (`/var/lib/quant`), `QUANT_GIT_URL`,
`QUANT_GITHUB_TOKEN` / `GITHUB_TOKEN`, `BIN_SRC`, `ENABLE=1` + `--compose PATH`.

Live configs are never overwritten. Binary replace is atomic.

If a Release has no asset, installer falls back to `cargo build` from that git tag
(needs Rust on the host).

## Uninstall

```bash
sudo ./uninstall.sh                 # interactive pick
sudo ./uninstall.sh --components lens,verify
sudo REMOVE_DATA=1 REMOVE_CONFIG=1 ./uninstall.sh --components all
```

## Self-test

```bash
./lib.sh --selftest
```
