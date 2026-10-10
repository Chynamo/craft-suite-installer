# Craft Suite â€” Windows installer

Twelve creative apps. One simple, offline installation.

**[Download the Windows x64 installer ZIP](https://github.com/Chynamo/craft-suite-installer/releases/download/v1.2.0-preview.1/Craft-Suite-Windows-x64-Setup.zip)** Â· [Release and checksum](https://github.com/Chynamo/craft-suite-installer/releases/tag/v1.2.0-preview.1)

## Install

1. Download **Craft-Suite-Windows-x64-Setup.zip** (about 638 MB).
2. Right-click the ZIP â†’ **Extract All**. Open the extracted folder.
3. Double-click **Setup.exe**, choose a folder and tick the apps you want and select **Install / update selected**.

Keep `InstallerData` beside `Setup.exe`. All apps are included: no downloads, account or administrator access is normally needed during installation. A USB copy works too.

![Installer screen](docs/installer.png)

## Add apps and update later

Run `Setup.exe` again and choose the **same installation folder**. Each card compares the installed version with the version in this ZIP: **Not installed**, **Up to date**, **Update available**, **Newer than this bundle**, or **Needs attention**.

New and outdated apps are selected by default. Unselected apps stay installed. Updates are installed alongside the old version, then the selected app's owned shortcuts switch to the new version. Older folders and your projects are retained; this installer does not silently downgrade or uninstall anything. Run a newly downloaded bundle to compare against its newer pinned versions. No internet check or automatic background updater is included.

The last successful graphical installation folder is remembered locally. Version labels are a quick inventory check; selected files are integrity-checked during installation. Keep all payloads in the ZIP even if installing only a few apps; selecting fewer apps reduces installed storage, not the download size.

## Included apps

FilmCraft Â· EffectCraft Â· SoundCraft Â· PhotoCraft Â· LightCraft Â· VectorCraft Â· DesignCraft Â· CADCraft Â· PdfCraft Â· WordCraft Â· GridCraft Â· DeckCraft.

For video, motion graphics, audio, photography, illustration, layouts, CAD and documents. Versions and original release links are in [bundle.lock.json](bundle.lock.json). ArtCraft Studio is excluded.

## Requirements and preview status

Windows 10/11 **x64**, built-in Windows PowerShell 5.1 and .NET Framework. Allow roughly **3 GiB free** when keeping the downloaded ZIP, extracted installer and installed apps on one drive. GPU requirements vary by app.

This is an **unofficial community preview**, maintained by Chynamo, containing unmodified releases from [the ArtCraft team](https://github.com/storytold). It is not endorsed by the original publisher. The launcher is unsigned, so Windows may show a security/reputation warning. Follow your device's security policy.

Selective installation, add/repeat safety, bundled-version comparisons, simulated upgrade/downgrade preservation, damaged-payload rejection and the graphical launcher were tested on the maintainer's Windows PC. A clean second PC, high-DPI screens and every app feature remain unverified. Report problems through [Issues](https://github.com/Chynamo/craft-suite-installer/issues); remove personal information from logs before sharing.

The installer preserves intact existing versions and refuses to overwrite changed original files. Keep your projects outside `Apps`. Personal projects, credentials and AI/MCP configurations are not included. It does not configure an AI service for you.

## Build from source

End users should download the installer ZIP above, **not GitHub's Source code ZIP**.

Maintainers need Windows x64, Python 3.11+ and the built-in .NET Framework C# compiler. Run `python build.py`. This downloads the pinned upstream ZIPs, checks their SHA-256 hashes, compiles the graphical launcher and writes the ZIP/checksum under `dist/`.

To reuse an existing official community bundle without redownloading: `python build.py --from-bundle "path/to/Craft-Suite-Windows-x64-Setup.zip"`. Use `--validate-only` to check inputs and compile the launcher without assembling the large output. No installation is performed by the builder. Rebuilt archives are not guaranteed byte-identical to the published ZIP.

## Licences

The installer wrapper is [MIT licensed](LICENSE). Each app, font and asset retains its upstream licence, copyright and notices in [third_party/Notices](third_party/Notices) and in the downloadable bundle. This repository does not relicense the apps or claim ownership of ArtCraft trademarks.
