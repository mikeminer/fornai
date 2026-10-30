# FORNAI Worker for macOS

Native macOS menu-bar companion for [fornai.dev](https://fornai.dev). Connect a local FreeLLMAPI instance, pair your Solana wallet, run assigned tasks and see earned Fornai credits. API credentials stay on your Mac in Keychain. The app connects out to Fornai; it does not expose the local API publicly.

## Platforms

- Apple Silicon: macOS 13.5 or later, arm64.
- Intel: macOS 13.5 or later, x86_64.

The app includes Node 24.21.0. FreeLLMAPI must already be configured and running on the same Mac. No Node installation is needed by end users.

## Download 0.2.0

- [Apple Silicon ZIP](https://fornai.dev/downloads/fornai-worker-macos-arm64.zip)
- [Intel ZIP](https://fornai.dev/downloads/fornai-worker-macos-x64.zip)

Both builds passed 19 Swift tests, 32 runtime tests and UI smoke tests on their respective macOS runners. See the [successful build](https://github.com/mikeminer/fornai/actions/runs/41050741064) and the setup guide for checksums and first-open instructions. The app is ad-hoc signed and is not Apple-notarized.

This version adds an optional web research agent using the search engines already configured in FreeLLMAPI. Enable research in the app, select Tavily, Exa or Firecrawl and set step/search limits. Choose **Ricerca web** on Fornai to submit a research job; older text-only workers cannot claim it.

See [the Italian setup guide](docs/MACOS-WORKER.md) for pairing, pause/start, credits and login options.

## Build and verify

On a Mac with Xcode command-line tools, use a clean checkout:

```sh
bash scripts/build-macos-worker.sh arm64
# On an Intel Mac:
bash scripts/build-macos-worker.sh x86_64
```

The build downloads the official Node archive, verifies a pinned SHA-256, compiles the native app, checks code signatures and architecture, runs policy and runtime tests, and renders a UI smoke-test image. ZIPs and SHA-256 files are written under `tools/macos-worker/build/<arm64|x64>/dist/`.

The GitHub Actions workflow uses separate native runners for each architecture. It requires no account credentials or production secrets. Apps built by this script have an ad-hoc signature, not an Apple Developer ID signature or notarization.

## Source layout

- `tools/macos-worker/Sources`: AppKit UI, Keychain, pairing and worker lifecycle.
- `scripts/tray-worker.mjs`: JSON-lines bridge for the native host.
- `scripts/worker-runtime.mjs`: task handling, receipts, retries and credential renewal.
- `tests` and `tools/macos-worker/Tests`: isolated tests with synthetic credentials.

This source package contains the desktop worker only. It contains no personal configuration, API keys, personal wallet addresses, payment records or backend deployment secrets. The Node license is included in each built app.
