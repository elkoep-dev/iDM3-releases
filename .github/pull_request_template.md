## What changes

<!-- Firmware and content are NOT added here. They are published from
     elkoep-dev/iDM-3.5.xx when a v* tag is cut, from the files in its Advance/ directory.
     A pull request here changes release notes, model aliases, tooling or documentation. -->

## Checklist

- [ ] `firmwares/`, `content/` and `catalog.xml` are untouched — a release regenerates them
- [ ] Release notes use the model name the catalogue uses, or an alias maps it
- [ ] Any new alias is `Confirmed="true"` only if it was actually verified against the product
- [ ] `.\tools\Test-Catalog.ps1` passes, if the tooling changed

## Field impact

<!-- Who sees this, and what happens if it is wrong on site?
     Release notes are read by a technician deciding whether to flash. A wrong model alias
     shows them another product's notes, which is worse than showing none at all. -->
