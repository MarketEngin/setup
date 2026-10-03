# Quant stack setup

Repos: [MarketEngin/setup](https://github.com/MarketEngin/setup)  
Release binaries: [MarketEngin/MarketEngin](https://github.com/MarketEngin/MarketEngin)

```text
/opt/quant/bin/{tape-capture,tape-sessionizer,quant,tape-lens,tape-verify}
/opt/quant/config/…
/var/lib/quant/{capture,sessions}
```

## Quick install (recommended)

**Do not** pipe into `sudo` (`curl | sudo bash` hangs — sudo reads the script
as the password). Pipe into `bash`; the script re-runs itself with `sudo`:

```bash
curl -fsSL https://raw.githubusercontent.com/MarketEngin/setup/main/get.sh | bash
```

With a GitHub token for private releases:

```bash
export QUANT_GITHUB_TOKEN=ghp_…
curl -fsSL https://raw.githubusercontent.com/MarketEngin/setup/main/get.sh | bash
```

Safe alternative (file on disk):

```bash
curl -fsSL https://raw.githubusercontent.com/MarketEngin/setup/main/get.sh -o /tmp/me-get.sh
sudo -E bash /tmp/me-get.sh
```

Non-interactive (CI / scripts):

```bash
curl -fsSL https://raw.githubusercontent.com/MarketEngin/setup/main/get.sh \
  | bash -s -- --components all --channel stable --yes
```

```bash
# Upgrade only newer tags
curl -fsSL https://raw.githubusercontent.com/MarketEngin/setup/main/get.sh \
  | bash -s -- --upgrade --components all --channel stable --yes
```

`get.sh` walks you through install / upgrade / uninstall, then downloads this
repo and runs `install.sh` / `uninstall.sh`.

| Env | Default |
|-----|---------|
| `QUANT_SETUP_URL` | `https://github.com/MarketEngin/setup` |
| `QUANT_SETUP_REF` | `main` |
| `QUANT_GIT_URL` | `https://github.com/MarketEngin/MarketEngin.git` |
| `QUANT_GITHUB_TOKEN` / `GITHUB_TOKEN` | optional (private releases) |

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

Each component resolves its own latest tag and downloads that release asset.
`--upgrade` skips components already ≥ latest (`manifest.json`).

## Install from a local checkout

```bash
git clone https://github.com/MarketEngin/setup.git && cd setup
sudo -E ./install.sh --components all --channel stable
sudo ./uninstall.sh
```

## Self-test

```bash
./lib.sh --selftest
```
