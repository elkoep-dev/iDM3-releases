# Security

## Reporting a vulnerability

Report suspected vulnerabilities in iNELS firmware, in iDM3 updates or in this repository
to **security@elkoep.cz**. Please include the device model and firmware version, what you
observed and how to reproduce it. Do not open a public issue.

## How downloads are protected

- The catalogue (`catalog.xml`) is signed. iDM3 only uses a catalogue whose signature
  matches the keys built into it.
- The catalogue lists a SHA-256 hash for every installer and firmware archive, and iDM3
  checks it before using a file.
- iDM3 never accepts an older catalogue than the one it already has.

## Withdrawn firmware

Withdrawn firmware is removed from the catalogue and is no longer offered. An archive that
is not listed in the current catalogue is not a supported release, even if it can still be
found in the history of this repository.
