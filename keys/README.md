# Signing keys

iDM3 trusts the catalogue because of a signature, not because of where it is hosted. The
public keys that verify that signature are compiled into the application. Everything in
this directory is public by design. **No private key is ever stored here** - `.gitignore`
blocks the usual file extensions, and `tools/New-SigningKey.ps1` refuses to write a private
key anywhere inside the repository.

## Current keys

| Role | File | Fingerprint | Generated | Custodian |
|---|---|---|---|---|
| Active | `idm3-catalog-active.public.xml` | _to be filled in_ | _to be filled in_ | _to be filled in_ |
| Standby | `idm3-catalog-standby.public.xml` | _to be filled in_ | _to be filled in_ | _to be filled in_ |

> Neither key has been generated yet. Both must exist and both must be pinned in iDM3
> before the first public release. See "Why two keys" below.

## Generating them

Run this on a trusted machine, not on a build agent, and not in CI:

```powershell
.\tools\New-SigningKey.ps1 -PrivateKeyPath E:\offline\idm3-catalog-active.private.xml  -Role Active
.\tools\New-SigningKey.ps1 -PrivateKeyPath E:\offline\idm3-catalog-standby.private.xml -Role Standby
```

Then commit the two `*.public.xml` files and their fingerprints, pin both public keys in
iDM3, and fill in the table above.

## Why two keys

A signing key that exists in one copy is a single point of failure that cannot be repaired
remotely. If the only pinned key is lost or compromised, every installation in the field
stops accepting updates, and the only fix is a new installer delivered by hand - which is
the exact problem this system exists to eliminate.

With a standby key already pinned, rotation is a publishing change: sign the next catalogue
with the standby key, and installations accept it immediately because they already trust it.

## Custody rules

- The private keys never touch this repository, a build agent, GitHub Actions secrets, or
  a developer workstation's normal filesystem.
- Offline storage only - a hardware token, or an encrypted volume held by two named people
  so that neither absence nor a single lost device blocks a release.
- The active and standby private keys are stored separately. Storing both in one place
  defeats the point of having two.
- Signing happens locally, by a person. CI only ever verifies.

## If a key is compromised

1. Sign the next catalogue with the **standby** key and publish it. Field installations
   accept it without any application update, because both keys are already pinned.
2. Generate a new standby key and pin it in the next iDM3 release.
3. Record the retired key's fingerprint below, with the date, so an old signature can be
   recognised during support.
4. Assume anything signed by the compromised key after the compromise date is untrusted -
   the catalogue `Sequence` number tells you which catalogues were published when.

## Retired keys

_None._
