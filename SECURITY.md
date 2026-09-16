# Security

## Reporting a vulnerability

Report suspected vulnerabilities in iNELS firmware, in the iDM3 update mechanism, or in
this repository to **security@elkoep.cz**.

> **TODO before publishing:** confirm this mailbox exists, is monitored, and has an owner.
> A public repository without a working contact address invites public disclosure instead.

Please include the affected device model and firmware version, what you observed, and how
to reproduce it. Do not open a public issue for a suspected vulnerability.

We will acknowledge within five working days.

## Verifying what you downloaded

Every archive in this repository is covered by a SHA-256 digest inside `catalog.xml`, and
`catalog.xml` is covered by the detached signature in `catalog.sig`. Verify in that order:
the signature over the catalogue first, then the digest of the file.

```powershell
.\tools\Test-Catalog.ps1 -Verify
```

Public keys are in [`keys/`](keys/). A firmware archive that is not listed in the current
signed catalogue is not a supported release, even if it is present in git history.

## Withdrawn firmware

Files in this repository are permanent - forks, clones and caches mean a published archive
can never truly be recalled. Withdrawal therefore works by removing the entry from the
catalogue, not by deleting the file. iDM3 only ever offers what the current signed
catalogue lists.
