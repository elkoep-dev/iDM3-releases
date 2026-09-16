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
| `catalog.xml` | Machine-readable index that iDM3 reads (added in phase 1) |
| `catalog.sig` | Detached signature over `catalog.xml` (added in phase 1) |
| `compatibility.xml` | Minimum recommended versions across the system (added in phase 1) |
| `keys/` | Public signing keys, for reference. Private keys are never stored here |
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

# 3. Regenerate and sign the catalogue with the offline private key
.\tools\Build-Catalog.ps1 -PrivateKeyPath E:\offline\idm3-catalog-active.private.xml

# 4. Verify it exactly as iDM3 will
.\tools\Test-Catalog.ps1

# 5. Commit and open a pull request
git add firmwares notes catalog.xml catalog.sig
git commit -m "Add NEW-MODEL 01.20.00"
```

## The catalogue

`catalog.xml` is the only file iDM3 has to trust: it carries a SHA-256 for every archive,
so the single signature in `catalog.sig` covers the whole repository. Entries are
path-based, so components other than firmware can be added later without changing the
schema or the client.

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
stays acceptable. Together they stop an old, validly-signed catalogue being replayed to
steer clients onto a withdrawn firmware.

CI validates naming, duplicate versions, catalogue-matches-disk and the signature before
the change can merge. Merging publishes it to every iDM3 installation on their next check.

## Trust model

Everything here is public, so **nothing trusts the host**. iDM3 verifies a detached
signature over the catalogue using a public key compiled into the application, then checks
the SHA-256 of every downloaded archive against the signed catalogue. A compromised
repository, a hostile proxy or a corporate TLS interceptor cannot cause iDM3 to install
firmware that ELKO EP did not sign.

See [`SECURITY.md`](SECURITY.md) for reporting, and [`keys/README.md`](keys/README.md) for
key custody.

## Licence

Firmware in this repository is proprietary. Public availability is not permission to
redistribute or modify it. See [`NOTICE.md`](NOTICE.md).
