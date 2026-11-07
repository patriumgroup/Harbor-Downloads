# Harbor downloads

Public downloads of compiled Harbor releases from Patrium Logistics LLC. The application source repository is private. Each release contains the Ubuntu binaries, runtime assets, and scripts needed to install, update, or uninstall Harbor, plus a separate SHA-256 checksum file. No installation secrets are packaged; they are generated on the host.

**Current status:** supervised technical alpha. Harbor is not ready for public multi-tenant production hosting. The current archive supports **Ubuntu 24.04 LTS amd64 only**; Ubuntu 26.04 is not supported yet.

[Download the current technical alpha](https://github.com/patriumgroup/Harbor-Downloads/releases/tag/v0.7.2-alpha.5) · [All releases](https://github.com/patriumgroup/Harbor-Downloads/releases)

`v0.7.2-alpha.3` fixes network address inspection and adds confirmed database, domain and site-owner removal, a managed NGINX rebuild action, automatic `www` website aliases, and HTTP server signature suppression. Site files and logs remain available after domain removal; owner home files are archived in a root-only directory. This release has passed disposable Ubuntu 24.04 installation tests; deploy it on a test host before accepting customer traffic.

`v0.7.2-alpha.4` adds version-suppressing defaults for optional Apache and removes product names from Harbor-managed Postfix and Dovecot greetings. Existing Harbor-managed mail configurations are backed up and updated during an upgrade.

`v0.7.2-alpha.5` checks HTTP-01 file verification for every requested website hostname and records certificate failures in the site's error log, including DNS, route, Certbot and NGINX diagnostics. A failed certificate row links directly to the log. The contact email is used for certificate notices, not verification.

For a fresh Ubuntu 24.04 amd64 host, run this one line in an interactive terminal:

```sh
wget -qO harbor-setup.sh https://raw.githubusercontent.com/patriumgroup/Harbor-Downloads/main/setup.sh && sudo bash harbor-setup.sh
```

The setup script prepares download tools, chooses the newest complete public release, verifies the downloaded archive against its checksum and public release asset digests. If the GitHub release API is unavailable, it selects the release from the public channel manifest, and starts the interactive installer. Setup and installation logs are saved under `/var/log/harbor/`; the final admin credential appears only in the terminal and in a root-only initial credential file. The checksum is supplied alongside the archive and is not an independent signature. Review the release notes and `LICENSE` in the archive before installation. Harbor's original code and compiled products require a separate written agreement with Patrium Logistics LLC; downloading them does not grant use or redistribution rights. Bundled third-party components retain their own licenses.

To **upgrade an existing Harbor installation** from a root console, run:

```sh
wget -qO harbor-setup.sh https://raw.githubusercontent.com/patriumgroup/Harbor-Downloads/main/setup.sh && bash harbor-setup.sh --upgrade
```

This uses the public release without a GitHub token or panel access. It verifies the release, refuses a downgrade, and creates a root-only backup before installation. Progress appears in the console and details are saved in `/var/log/harbor/upgrade-*.log`. Keep the console open until the command finishes. Harbor currently supports Ubuntu 24.04 LTS amd64 only.

For product information and commercial inquiries, visit [Patrium Logistics LLC](https://www.patrium.net/).
