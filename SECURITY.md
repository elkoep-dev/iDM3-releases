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

Every archive is covered by a SHA-256 digest inside `catalog.xml`:

```powershell
.\tools\Test-Catalog.ps1
```

A firmware archive that is not listed in the current catalogue is not a supported release,
even if it is present in git history.

## What this repository does and does not protect against

**The catalogue is not signed.** Authenticity rests on HTTPS to GitHub and on who can push
here. Be explicit about what that covers:

| Threat | Protected? |
|---|---|
| Archive corrupted in transit or on disk | Yes — SHA-256 in the catalogue |
| Hostile proxy or TLS interception | Yes — iDM3 validates the certificate itself rather than inheriting the application's permissive global callback |
| Old catalogue replayed to re-offer withdrawn firmware | Yes — `Sequence` may not move backwards, and `ValidUntil` bounds its life |
| Someone who can push to this repository | **No** |
| A stolen GitHub token or a compromised maintainer account | **No** |

The last two were never covered by anything. The iDM3 installer is built by CI from the
same GitHub organisation, so whoever can push there has always decided what firmware
reaches a central unit. Publishing firmware here does not widen that exposure.

This is why the catalogue carries **content only** — files that are read, never executed.
`cmp.exe` and everything iDM3 loads ship in the installer instead, and `Test-Catalog.ps1`
fails the build if an executable reaches the catalogue, by extension or inside an archive.
Without a signature, an executable delivered this way would turn a stolen token into code
execution on an engineer's machine, which is a different class of problem from a bad
firmware image.

## Withdrawn firmware

Files in this repository are permanent - forks, clones and caches mean a published archive
can never truly be recalled. Withdrawal therefore works by removing the entry from the
catalogue, not by deleting the file. iDM3 only ever offers what the current catalogue lists.
