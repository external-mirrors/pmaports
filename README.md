# KDE Nightly

This branch includes APKBUILDs to build all of KDE nightly straight from git master.
It's not intended to be used on systems that people rely on, rather it's meant to ease development and for easy testing.

See https://wiki.postmarketos.org/Nightly for more details.

## Disabled packages

Sometimes packages don't build due to various external reasons.
These are removed from the repo to allow building the rest of the repository but will have to be re-added once they're fixed.
They can be restored with `git checkout <commit they were removed in>^ -- packages/<package name>`).

Here is the current list:
- `akonadiconsole`, it's dependency `xapian-bindings` is currently disabled in Alpine
- `oxygen`, requires currently unmerged PR's
- `kimagemapeditor`, currently incompatible with `kio`
- `k3b`, currently incompatible with `kbookmarks`
