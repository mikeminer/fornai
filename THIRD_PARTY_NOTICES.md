# Third-party notices

This document identifies third-party components used by the FORNAI macOS worker. The FORNAI project license and any copyright notice naming mikeminer apply only to material for which the project holds the relevant rights. They do not replace, restrict, or relicense the third-party components below. Those components remain subject to their own licenses and notices.

This inventory concerns the macOS worker source package and its generated app bundles. It does not cover the separately installed FreeLLMAPI application, external API services, or repositories and search excerpts retrieved by users. Their respective rights and terms remain applicable.

## Node.js included in the app

The app bundles the official **Node.js v24.21.0** executable. Node.js is copyright Node.js contributors, with additional notices for Joyent and other contributors. Its license file contains the Node.js MIT terms and the separate notices and licenses for its included dependencies. The full file, rather than this summary, governs those components.

- Upstream: [Node.js v24.21.0](https://github.com/nodejs/node/tree/v24.21.0).
- Complete license: [Node.js v24.21.0 LICENSE](https://github.com/nodejs/node/blob/v24.21.0/LICENSE).
- Bundled executable: `FORNAI Worker.app/Contents/Resources/runtime/node`.
- Bundled full notices: `FORNAI Worker.app/Contents/Resources/runtime/NODE-LICENSE.txt`.

The build copies the complete upstream license from the downloaded archive. Preserve that file when distributing the app or the Node.js binary. A FORNAI license must not be substituted for it.

The build pins these official archives and checks their SHA-256 before packaging:

| Archive | SHA-256 |
| --- | --- |
| `node-v24.21.0-darwin-arm64.tar.gz` | `bed7eea5325e1108f32ce5228ddd6a5f0f08a499ee42aa7442aea583702f6057` |
| `node-v24.21.0-darwin-x64.tar.gz` | `1462cb3b3046b815cf8ea436d3da450ec1a9f11dac7e5a46b0ada5305d7e8097` |

Upstream verification record: [Node.js v24.21.0 SHASUMS256.txt](https://nodejs.org/download/release/v24.21.0/SHASUMS256.txt).

## GitHub Actions used during builds

The workflow references these actions by immutable commit. Their implementation and dependencies execute on the build runner; the packaging script does not copy them into the FORNAI app or this source repository. The entries below document build provenance, not additional app contents.

| Action | Version and pinned commit | Upstream license |
| --- | --- | --- |
| `actions/checkout` | v7.0.1 — `3d3c42e5aac5ba805825da76410c181273ba90b1` | [MIT; copyright GitHub, Inc. and contributors](https://github.com/actions/checkout/blob/3d3c42e5aac5ba805825da76410c181273ba90b1/LICENSE) |
| `actions/upload-artifact` | v7.0.2 — `cf430e030ddbb5b0abf93d22962f4752f3646cd9` | [MIT; copyright GitHub, Inc. and contributors](https://github.com/actions/upload-artifact/blob/cf430e030ddbb5b0abf93d22962f4752f3646cd9/LICENSE) |

## Platform and source dependencies

The native sources use Apple system frameworks, including AppKit, Combine, Foundation, Security, ServiceManagement and CoreServices. The build uses the macOS SDK and Swift compiler supplied by the selected Xcode installation. The build script does not package an SDK, compiler, or separately downloaded copy of those frameworks. Their use does not make them FORNAI-owned material. The upstream Swift project publishes its [license and runtime-library exception](https://github.com/swiftlang/swift/blob/main/LICENSE.txt); the actual compiler version is determined by the build environment, not pinned as a vendored project dependency.

The JavaScript worker and tests import Node.js built-in modules and project-local modules. This source package does not vendor npm packages or Swift packages. Project-specific source files, tests, documentation and FORNAI artwork are separate from the third-party components identified here; this inventory does not assign their ownership to any third-party project.

## Distribution records

Keep the applicable FORNAI project license, this notice, and the full Node.js license as separate documents in future release bundles. Updating a component requires reviewing its version-specific notices and updating this inventory. Links in this document identify upstream sources; they do not replace license texts that must accompany redistributed components. No endorsement by Node.js contributors, GitHub, Apple, or other component owners is implied.
