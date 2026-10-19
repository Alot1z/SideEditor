# SideEditor foundation evidence

Date: 2026-10-19

## Fork

- Repository: <https://github.com/Alot1z/SideEditor> (private)
- Upstream: <https://github.com/SideStore/SideStore>
- Base commit: `d97ec133719d79916675bdaf722b82a8d091d545` (`develop`, 2026-10-16)
- Working branch: `sideeditor`
- Submodules: SideSign `752d1ef602aa792a432ffa1e71646dc1ecf7363c`, minimuxer `12be70dc2627307a16bfd2dc7a009080d5bec909`
- Commits:
  - `f521e5f25e051ae10b5fddd0bf6403eb47383f09` — add CI workflow
  - `4c49a42f2900d8d2b3638c3fc8ab89fe8c0dd003` — display name SideEditor
- Local commit guard: `.git/hooks/commit-msg` strips AI/harness attribution trailers.
- All upstream workflows (alpha, nightly, PR, stable, triage, artifact-links) are disabled in the fork; only `SideEditor CI` is active. This prevents accidental scheduled/dispatch runs or upstream-facing automation.
- No PR, issue, comment, or automated posting against SideStore/SideStore.

## Baseline CI — untouched upstream source

- Run: `39290607790`
- URL: <https://github.com/Alot1z/SideEditor/actions/runs/39290607790>
- Head: `f521e5f25e051ae10b5fddd0bf6403eb47383f09`
- Result: **success** (`completed` / `success`)
- Artifact: `SideStore-baseline` (id `12205842878`, 30,991,249 bytes archive)
- Downloaded file: `artifacts/baseline/SideStore.ipa`, 31,044,148 bytes
- File SHA-256: `07ef06daf7b8bb48caa667863067a33c2ffb1b7a214d5071f29112e6d3e76fa6`
- Inspected: `Payload/SideStore.app`, `CFBundleIdentifier=com.SideStore.SideStore`, `CFBundleName=SideStore`, no `CFBundleDisplayName`, `CFBundleExecutable=SideStore`, `MinimumOSVersion=15.0`, `UIDeviceFamily=[1,2]`, no `embedded.mobileprovision`.

## Rename CI — display name SideEditor

- Run: `39293131567`
- URL: <https://github.com/Alot1z/SideEditor/actions/runs/39293131567>
- Head: `4c49a42f2900d8d2b3638c3fc8ab89fe8c0dd003`
- Result: **success** (`completed` / `success`)
- CI identity gate: `{'CFBundleDisplayName': 'SideEditor', 'CFBundleIdentifier': 'com.SideStore.SideStore', 'CFBundleName': 'SideStore', 'CFBundleExecutable': 'SideStore'}` → `identity: ok`
- Artifact: `SideEditor` (id `12206332341`, 30,991,199 bytes archive)
- Downloaded file: `artifacts/rename/SideEditor.ipa`, 31,044,158 bytes
- File SHA-256: `f2a8e513ae8831c29a66ee20534410c398e104309276a27cdb95ba83fdcde971`
- Inspected: `Payload/SideStore.app`, `CFBundleDisplayName=SideEditor`, `CFBundleIdentifier=com.SideStore.SideStore` (unchanged), `CFBundleName=SideStore`, `CFBundleExecutable=SideStore`, `MinimumOSVersion=15.0`.
- Internal target names and bundle ID were left unchanged as planned.
- Source delta is only the `CFBundleDisplayName` key. The rebuilt IPA has 8 differing entries versus baseline (Info.plist, app-intents UUID/metadata, widget binary, nested `SideBackup.ipa`) because the build is not reproducible; the main app executable hash is identical. This is build nondeterminism, not a second source change.

## Not proven yet

- No device install or launch (SideStore/TrollStore/LiveContainer) was performed.
- No local macOS/Xcode build exists; CI is the only compile oracle.
- xtool is not installed on this Windows host and was not exercised.
- The editor, entitlement editing, unsigned export, LiveContainer and StikDebug work are not implemented in this phase.
- The built app still contains nested framework signatures (for example `Frameworks/OpenSSL.framework/_CodeSignature`); upstream `make fakesign` only fakesigns the main app and widget. A future unsigned/strip pipeline must remove nested signatures recursively.
