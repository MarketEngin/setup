# Quant stack setup

Repos: [MarketEngin/setup](https://github.com/MarketEngin/setup)  
Release binaries: [MarketEngin/MarketEngin](https://github.com/MarketEngin/MarketEngin)

```text
/opt/quant/bin/{tape-capture,tape-sessionizer,quant,tape-lens,tape-verify}
/opt/quant/config/…
/var/lib/quant/{capture,sessions}
/opt/quant/manifest.json   # per-component installed tags
```

## Quick install (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/MarketEngin/setup/main/get.sh | bash
```

**Never** use `curl | sudo bash` (sudo steals the pipe and hangs). The script self-elevates with `sudo` after a labeled self-copy when needed.

### Flow (ask first, download after)

1. **Questions** — mode (install / upgrade / uninstall), channel, apps, optional GitHub token, paths  
2. **Plan** — resolve latest tags via `git ls-remote` (metadata only) and show what will change  
3. **Confirm**  
4. **Per-app download** — only selected apps that need work, with curl progress and step narration:

```text
◆ [1/3] tape-capture — downloading tape-capture-v1.0.0 (tape-capture-linux-amd64.tar.gz)
######################################################################## 100.0%
◆ extracting…
◆ installing → /opt/quant/bin/tape-capture
✓ tape-capture done (tape-capture-v1.0.0)
```

Nothing product-related is downloaded before you confirm. If the script must copy itself for sudo when piped, it prints that explicitly (`NOT downloading your apps`).

With a GitHub token for private releases:

```bash
export QUANT_GITHUB_TOKEN=ghp_…
curl -fsSL https://raw.githubusercontent.com/MarketEngin/setup/main/get.sh | bash
```

Non-interactive:

```bash
curl -fsSL https://raw.githubusercontent.com/MarketEngin/setup/main/get.sh \
  | bash -s -- --components all --channel stable --yes
```

File form (if the pipe stalls):

```bash
curl -fsSL https://raw.githubusercontent.com/MarketEngin/setup/main/get.sh -o /tmp/me-get.sh
sudo -E bash /tmp/me-get.sh
```

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

## Upgrade

Upgrade is **per component**, not one global VERSION:

1. List remote tags on `QUANT_GIT_URL` for the chosen channel  
2. Read installed tag from `$PREFIX/manifest.json` (`components.<name>.tag`)  
3. If latest ≤ installed (same channel) → **skip** (no download)  
4. If newer or missing → download that release asset with the same progress narration as install  
5. Config files are never overwritten  

Interactive: choose **Upgrade** in the wizard (or pass `--upgrade`).  
CI: `sudo ./install.sh --upgrade --channel stable --components sessionizer,quant`

If every selected app is already current, the installer exits with “up to date” and downloads nothing.

## Install from a local checkout

```bash
git clone https://github.com/MarketEngin/setup.git && cd setup
sudo -E ./get.sh                  # interactive
sudo -E ./install.sh --components all --channel stable   # non-interactive / CI
sudo ./uninstall.sh
```

`install.sh` shares `lib.sh` with `get.sh` (same plan + narrated download path for `--source git`).

## Self-test

```bash
./lib.sh --selftest
```
