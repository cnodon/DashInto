# Third-party notices

Clash Dash is an independent iOS client. It does not imply affiliation with Clash Verge Rev, ProjectClash, MetaCubeX, Dreamacro or SagerNet.

| Component | Pinned source | License |
| --- | --- | --- |
| ProjectClash Apple core, mihomo 1.19.33 derivative | [7f6b34584e4aa67f37239a9ca2a3a49b578639e3](https://github.com/ProjectClash/Clash/tree/7f6b34584e4aa67f37239a9ca2a3a49b578639e3), release v1.19.33-clash.3 | GPL-3.0-or-later; see `Vendor/LICENSE` and `Vendor/NOTICE` |
| PacketFlowBridge / ProviderLifecycle | [bdf40d4148eca4ead785fe54d724abd79d020876](https://github.com/ProjectClash/Clash-Adapter/tree/bdf40d4148eca4ead785fe54d724abd79d020876) | GPL-3.0-or-later; see `Vendor/ClashAdapter/LICENSE` |
| Yams 5.4.0 | [tag 5.4.0](https://github.com/jpsim/Yams/tree/5.4.0) | MIT; see `Vendor/Yams/LICENSE` |

The SDK's original `NOTICE`, `SOURCES.json`, `THIRD_PARTY_LICENSES.md` and complete `THIRD_PARTY_LICENSES/` directory are preserved under `Vendor/`. They include the upstream notices for statically linked dependencies, generated bridge runtime and embedded components. Yams also preserves its libyaml license. The App bundles the SDK's complete third-party notices, GPL text and Yams license; these are readable under Settings → Open-source licenses.

`Dependencies.lock.json` pins the SDK archive hash, source commit and adapter file hashes. `Scripts/bootstrap.py` checks the downloaded artifact before extraction. The binary XCFramework is locally downloaded development material and excluded from source control; it is restored by bootstrap.

The pinned core is linked into the App for offline node import/resource planning/semantic preflight, and into the Packet Tunnel Extension for the network runtime. Only the extension starts a network service.

`Fixtures/Imports/ShadowrocketExports.json` is the synthetic exporter corpus from the pinned core revision; provenance and license are recorded in `Fixtures/Imports/NOTICE.md`. It contains no user account or subscription credentials.

The installed Clash Verge `verge-mihomo` executable is used only as a separate reference process for the optional local integration laboratory. It is not copied into, linked into, or redistributed with the iOS App. No Clash Verge UI source has been copied into the App.

Before any binary distribution, retain these notices and provide the complete corresponding source and build information for the precise distributed version, including upstream components and local modifications. No binary distribution has been performed in this workspace.
