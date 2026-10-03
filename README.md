# Quant stack setup

Repos: [MarketEngin/setup](https://github.com/MarketEngin/setup)  
Release binaries: [MarketEngin/MarketEngin](https://github.com/MarketEngin/MarketEngin)

Installs to:

```text
/opt/quant/bin/{tape-capture,tape-sessionizer,quant,tape-lens,tape-verify}
/opt/quant/config/…
/var/lib/quant/{capture,sessions}
```

## Quick install (no clone)

One command on a Linux host with `curl` + `sudo` — downloads this installer
and runs it (same idea as rustup / docker install scripts):

```bash
# Stable (all components)
curl -fsSL https://raw.githubusercontent.com/MarketEngin/setup/main/get.sh \
  | sudo bash -s -- --components all --channel stable
```

```bash
# Pre-release channel
curl -fsSL https://raw.githubusercontent.com/MarketEngin/setup/main/get.sh \
  | sudo bash -s -- --components all --channel pre-release
```

```bash
# Private MarketEngin releases — pass a token through
export QUANT_GITHUB_TOKEN=ghp_…   # Contents read on MarketEngin/MarketEngin
curl -fsSL https://raw.githubusercontent.com/MarketEngin/setup/main/get.sh \
  | sudo -E bash -s -- --components all --channel stable
```

```bash
# Upgrade only what is newer
curl -fsSL https://raw.githubusercontent.com/MarketEngin/setup/main/get.sh \
  | sudo -E bash -s -- --upgrade --channel stable --components sessionizer,quant
```

`get.sh` pulls the setup tree for ref `main` (override with `QUANT_SETUP_REF`),
then runs `install.sh` with your flags. Defaults:

| Env | Default |
|-----|---------|
| `QUANT_SETUP_URL` | `https://github.com/MarketEngin/setup` |
| `QUANT_SETUP_REF` | `main` |
| `QUANT_GIT_URL` | `https://github.com/MarketEngin/MarketEngin.git` |
| `QUANT_GITHUB_TOKEN` / `GITHUB_TOKEN` | (optional; needed if MarketEngin is private) |

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

## Install from a local checkout

```bash
git clone https://github.com/MarketEngin/setup.git
cd setup
sudo -E ./install.sh --components all --channel stable
```

```bash
# Local binaries instead of GitHub Releases
sudo ./install.sh --source local --bin-src /path/to/bins --components quant,lens

# Dry-run
DRY_RUN=1 ./install.sh --components all --channel pre-release --dry-run
```

Env: `PREFIX` (`/opt/quant`), `DATA_DIR` (`/var/lib/quant`), `BIN_SRC`,
`ENABLE=1` + `--compose PATH`.

Live configs are never overwritten. Binary replace is atomic.

If a Release has no asset, installer falls back to `cargo build` from that git
tag (needs Rust on the host).

Systemd templates ship in `systemd/`. Instances are enabled by
`quant -f … up -d`, not by the installer alone.

## Uninstall

```bash
# From a checkout
sudo ./uninstall.sh

# Or one-liner (same bootstrap)
curl -fsSL https://raw.githubusercontent.com/MarketEngin/setup/main/get.sh \
  | sudo bash -s -- --help   # get always runs install.sh — use clone for uninstall
```

For uninstall, clone or download the repo once:

```bash
curl -fsSL https://codeload.github.com/MarketEngin/setup/tar.gz/refs/heads/main \
  | tar xz && cd setup-main && sudo ./uninstall.sh
```

## Self-test

```bash
./lib.sh --selftest
```
