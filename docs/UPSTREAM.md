# Upstream pin and fork policy

SideEditor is a fork of [SideStore/SideStore](https://github.com/SideStore/SideStore).

- Pinned upstream commit: `d97ec133719d79916675bdaf722b82a8d091d545` (`develop`, 2026-10-16)
- Pinned submodules: SideSign `752d1ef602aa792a432ffa1e71646dc1ecf7363c`, minimuxer `12be70dc2627307a16bfd2dc7a009080d5bec909`
- Fork remote: `origin` → <https://github.com/Alot1z/SideEditor>
- Upstream remote: `upstream` → <https://github.com/SideStore/SideStore> (fetch only)

Policy:

- Never push to `upstream`.
- Never open a pull request, issue, discussion comment, or automated GitHub posting against SideStore/SideStore or any upstream project.
- All GitHub activity stays on `Alot1z/SideEditor`.
- SideStore is AGPL-3.0. SideEditor distributions must keep the licence and offer corresponding source.
- Do not commit pairing files, certificates, private keys, Apple IDs, passwords, or device UDIDs.

Updating the pin is a deliberate change: fetch the new upstream commit, record its full SHA here, rebuild in CI, and verify the identity/export gates before merging.
