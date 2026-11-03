# Harbor downloads

Public downloads of compiled Harbor releases from Patrium Logistics LLC. The application source repository is private. Each release contains the Ubuntu binaries, runtime assets, and scripts needed to install, update, or uninstall Harbor, plus a separate SHA-256 checksum file. No installation secrets are packaged; they are generated on the host.

**Current status:** supervised technical alpha. Harbor is not ready for public multi-tenant production hosting. The current archive supports **Ubuntu 24.04 LTS amd64 only**; Ubuntu 26.04 is not supported yet.

[Download the current technical alpha](https://github.com/patriumgroup/Harbor-Downloads/releases/tag/v0.7.1-alpha.3) · [All releases](https://github.com/patriumgroup/Harbor-Downloads/releases)

Verify the downloaded archive before installing:

```sh
sha256sum -c harbor-v0.7.1-alpha.3-ubuntu24.04-amd64.tar.gz.sha256
```

The checksum detects accidental corruption. It is supplied alongside the archive and is not an independent signature. Review the release notes and `LICENSE` in the archive before installation. Harbor's original code and compiled products require a separate written agreement with Patrium Logistics LLC; downloading them does not grant use or redistribution rights. Bundled third-party components retain their own licenses.

For product information and commercial inquiries, visit [Patrium Logistics LLC](https://www.patrium.net/).
