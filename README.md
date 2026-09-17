# iDM3 Releases

Firmware, release metadata and documentation for the **iNELS BUS** system, published by
ELKO EP. This repository is the source of truth that the **iDM3** configuration tool reads
to discover and download device firmware.

Before this repository existed, every firmware change required a full iDM3 release and a
new installer sent to each customer by hand. Publishing a firmware is now a commit.

## What is here

| Path | Contents |
|---|---|
| `firmwares/` | Device firmware archives, one per model and version |
| `catalog.xml` | Machine-readable index that iDM3 reads |
| `notes/` | Per-model release notes, and `model-aliases.xml` |
| `tools/` | Publishing and validation scripts |

## Firmware naming

Archives keep the exact names iDM3 already uses, so a downloaded file drops straight into
the tool's `Firmwares` folder and the existing flashing path works unchanged:

```
MODEL_MM.mm.pp.zip        e.g. GCH3-31_02.A0.00.zip
```

The version is hexadecimal, matching the value the unit itself reports. Inside each archive
is the firmware image (`.if3` for bus units, `.nf3` for central units), the device's
`unit.xml` model, and for central units a `firmDepends.xml` hardware dependency map.

`tools/Test-FirmwareNames.ps1` enforces this, and CI runs it on every pull request.

## Publishing a firmware

```powershell
# 1. Add the archive
Copy-Item .\NEW-MODEL_01.20.00.zip .\firmwares\

# 2. Add its release notes to notes\NEW-MODEL.xml, or regenerate them all from the
#    history files that ship with iDM3
.\tools\Import-FirmwareHistory.ps1 -HistoryPath "...\Advance\Documentation\Firmware history"

# 3. Regenerate the catalogue
.\tools\Build-Catalog.ps1

# 4. Verify it exactly as iDM3 will
.\tools\Test-Catalog.ps1

# 5. Commit and open a pull request
git add firmwares notes catalog.xml
git commit -m "Add NEW-MODEL 01.20.00"
```

Steps 3 and 4 are optional: pushing to `main` regenerates and validates the catalogue in
CI. Running them locally just means you see the result before anyone else does.

## Working on macOS or Linux

The tooling is PowerShell and runs anywhere [PowerShell 7](https://github.com/PowerShell/PowerShell)
does - `brew install powershell` on a Mac, then `pwsh`.

Nothing in the publishing path is Windows-only, and nothing needs to be installed at all if
you let CI regenerate the catalogue.

## The catalogue

`catalog.xml` is the index iDM3 reads. It carries a SHA-256 for every archive, so the
catalogue alone determines whether a downloaded file is intact. Entries are path-based -
each `Item` names the `Target` path it belongs at inside the installation - so components
other than firmware can be added without changing the schema or the client.

```xml
<Item Component="Firmwares" Kind="Firmware" Model="GCH3-31" Version="02.9E.00"
      Target="Firmwares\GCH3-31_02.9E.00.zip" Source="firmwares/GCH3-31_02.9E.00.zip"
      Size="59520" Sha256="3c722a41..." Channel="Stable">
  <Note Lang="en">support for hardware with out ligth sensor</Note>
</Item>
```

`Kind` matters. `Firmwares/` has always held three different things and only one of them
can be flashed, so iDM3 offers `Kind="Firmware"` and nothing else:

| Kind | Contents | Count |
|---|---|---|
| `Firmware` | a `.if3` / `.nf3` image | 128 |
| `Definition` | only `unit.xml` - a device model, nothing to flash | 16 |
| `Placeholder` | an empty archive - a virtual module inside the central unit | 26 |

`Sequence` increases with every publication and `ValidUntil` bounds how long a catalogue
stays acceptable. Together they stop an old catalogue being replayed to steer clients onto
a withdrawn firmware: iDM3 refuses a catalogue whose `Sequence` is below the one it has
already cached.

CI validates naming, duplicate versions, catalogue-matches-disk, and that no `Item` carries
executable content, before the change can merge. Merging publishes it to every iDM3
installation on their next check.

## Trust model

**The catalogue is not signed.** Authenticity rests on HTTPS to GitHub and on who can push
here — the same boundary firmware always had, since the iDM3 installer is built by CI from
the same GitHub organisation. Whoever can push has always decided what reaches a central
unit. Signing would have been an improvement on that, not a precondition for matching it.

Two things do the work:

- **iDM3 validates the server certificate itself.** It does not inherit the process-wide
  callback `UpdateManager` installs for the legacy server's self-signed certificate, which
  accepts untrusted roots. Without that override there would be no transport protection at
  all, and a hostile proxy or a corporate TLS interceptor would be enough.
- **Every archive is checked against the SHA-256 in the catalogue** before it is offered,
  so a corrupted or swapped archive is rejected.

### What the catalogue may carry

**Content only — files that are read, never executed.** Firmware, release notes, languages,
device definitions, documentation.

Executables stay in the installer. `cmp.exe` and everything iDM3 loads are delivered that
way, and `Test-Catalog.ps1` fails the build if an executable reaches the catalogue, by
extension or inside an archive. The reason is the absence of a signature: an executable
delivered through an unsigned channel turns a stolen repository token into code execution
on every engineer's machine, which is a different class of problem from a bad firmware
image. A firmware image is read by a central unit that validates it; an `.exe` is run by
Windows on a laptop.

If that boundary ever needs to move, the answer is a code-signing certificate for the
executables, not signing the catalogue.

See [`SECURITY.md`](SECURITY.md) for reporting.

## Licence

Firmware in this repository is proprietary. Public availability is not permission to
redistribute or modify it. See [`NOTICE.md`](NOTICE.md).
