# SideEditor

> SideEditor is a *SideStore fork* — the original `SideStore` app (`SideStore/SideStore`) rewritten as a **new app named `SideEditor`**.

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://makeapullrequest.com)

![Repobeats analytics image](https://repobeats.axiom.co/api/embed/3a329ce95955690b9a9366f8d5598626a847d96c.svg "Repobeats analytics image")

SideEditor is what the SideStore project became when it was retargeted at a **new app name and a new build pipeline**. It is a fork of the original SideStore work, not a new, unrelated project. The **UI, screens, and most of the app logic are unchanged** — they reuse SideStore's existing `AltStore` target surface directly.

## What changed (and what did not)

- **App name:** the app is now `SideEditor`. It builds a distinct IPA with `CFBundleDisplayName` = `SideEditor`.
- **Signing:** the CI IPA is fake-signed with `ldid` (no `_CodeSignature/CodeResources`), exactly like upstream SideStore's free-team builds. It is a build artifact, not an App Store or development-signed install; SideEditor re-signs apps on-device with the user's Apple ID.
- **UI and behavior:** unchanged from SideStore. You get the same Browse / My Apps / Settings / News screens, the same app ID handling, same permissions, same unauthorised-sideloading model.
- **Build tooling:** reuse of SideStore's `AltStore.xcodeproj`. The project has exactly one application target (`SideStore`) and one app scheme; the SideEditor identity comes from `PRODUCT_NAME = SideStore` in `Build.xcconfig` plus `CFBundleDisplayName = SideEditor` in `AltStore/Info.plist`. The `SideEditor/` folder holds the editor surface sources (`SideEditorCore`, `SideEditorSetup`, `SideEditorTab`, `SideEditorViews`), which are not yet wired into the application target, so they are not compiled into the IPA.
- **CI:** `.github/workflows/sideeditor-build.yml` builds on `macos-26` through the project's own Makefile pipeline (`make build`, `make fakesign`, `make ipa`), validates `project.pbxproj` with `scripts/ci/pbxproj_lint.py`, verifies the built bundle identity and embedded `AltWidgetExtension.appex`, and uploads `SideEditor.ipa` as a workflow artifact. It publishes no GitHub Release.
- **Source:** the SideEditor fork lives at `https://github.com/Alot1z/SideEditor` (a fork of `SideStore/SideStore`).

## Requirements

- Xcode 15
- iOS 14+
- Rustup (`brew install rustup`)
- macOS host for local builds and packaging

## Project Overview

See the original SideStore README for the technical overview of the pieces that are **reused unchanged**:

- **SideStore** — the sandboxed iOS application that contains the vast majority of the app logic, including all the logic for downloading and updating apps.
- **EM Proxy** — powers untethered app installation via a custom App Store app and `LocalDevVPN` to create the VPN tunnel.
- **Minimuxer** — a lockdown muxer that runs inside iOS's sandbox and replicates Apple's `usbmuxd` protocol on macOS.
- **Roxas** — Riley Testut's internal framework from AltStore; the SideEditor fork inherits this dependency.

## Contributing / Compilation Instructions

Please see [CONTRIBUTING.md](./CONTRIBUTING.md).

## Licensing

This project is licensed under the **AGPLv3 license**.

- **AGPL-3.0 applies to the SideStore-derived code** that is now built as `SideEditor`. You may use, modify, build on, and sell it.
- You may also make your own fork of this project.
- If you distribute a modified version, or make the modified version available as a network service, you must, under the conditions of AGPL-3.0, make the corresponding source code available to users of that server.
- If you run a modified version **only for yourself** (no distribution), no source availability is required.
- You must not remove copyright or license notices, and you cannot relicense this code under a different, non-AGPL license.

The full license text is in [LICENSE](./LICENSE).
