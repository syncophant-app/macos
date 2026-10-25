# Rebuilding and replacing bundled libraries

Release packaging supplies the exact application source, build scripts, lockfile
and assets in `Syncophant-<version>-source.tar.gz`. The separate
`AMSMB2-4.0.3-source.tar.gz` includes AMSMB2 and its pinned libsmb2 submodule,
licenses and component notices. The app bundles the LGPL text and the compiled
crypt helper's aggregate Go/rclone notices. Preserve these alongside binaries.

Build prerequisites and commands are in the root README. `bootstrap.sh` verifies
and builds the pinned SSH/OpenSSL sources. Go builds the crypt helper; it is not
a runtime requirement. Package.resolved pins Swift dependencies.

AMSMB2 is dynamically linked. To rebuild a modified library, unpack its source,
make the changes, and replace the AMSMB2 package declaration in Package.swift
with `.package(path: "/absolute/path/to/AMSMB2")`. The application source is
provided so it can be rebuilt/relinked against that package with a compatible
Swift compiler. Rebuild the app and extension with `bash scripts/build.sh`.

macOS hardened-runtime signature checks apply to replaced frameworks. Re-sign
the framework and containing bundles with your own identity; `scripts/sign.sh`
shows the required nested signing order. An ad-hoc build can exercise the UI,
but Finder integration requires your own app/extension provisioning. Change the
bundle IDs, app group, Keychain group and SSH-agent peer requirements consistently
in Config, SharedConfig/SSHAgentBrokerPolicy and generate-project.rb, and register
those identifiers with your team. Original project signing keys are not included
or needed to build modified source. Do not reuse an official signature or claim
that a modified build is an official release.

`scripts/package.sh` produces an app ZIP, both source archives and SHA256 files.
For a configured Developer ID team, set SYNCOPHANT_TEAM_ID and
SYNCOPHANT_DISTRIBUTION=1. Its output is explicitly **not notarized**; a successful
build/signature check does not establish Apple notarization or publication.

## Notarization

Store Apple credentials privately in a local notarytool Keychain profile; never
put passwords in arguments, source or release metadata. With the existing
`syncophant-notary` profile, the verified workflow is:

```sh
xcrun notarytool submit build/Syncophant-0.1.0-arm64-signed-not-notarized.zip --keychain-profile syncophant-notary --wait
xcrun stapler staple build/DeveloperID/Build/Products/Release/Syncophant.app
xcrun stapler validate build/DeveloperID/Build/Products/Release/Syncophant.app
codesign --verify --deep --strict build/DeveloperID/Build/Products/Release/Syncophant.app
spctl --assess --type execute --verbose=2 build/DeveloperID/Build/Products/Release/Syncophant.app
ditto -c -k --sequesterRsrc --keepParent build/DeveloperID/Build/Products/Release/Syncophant.app build/Syncophant-0.1.0-arm64.zip
shasum -a 256 build/Syncophant-0.1.0-arm64.zip > build/Syncophant-0.1.0-arm64.zip.sha256
```

Require an Accepted submission with no issues before stapling. Validate the
ticket and Gatekeeper assessment again on a fresh ZIP extraction. Do not rebuild
or re-sign after stapling; create the final archive from the ticketed app.
Adjust the version/architecture paths for a new build. Apple acceptance does
not publish a GitHub release or complete runtime acceptance testing.
