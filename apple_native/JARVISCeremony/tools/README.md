# JARVISCeremony tooling

## Notarization credentials

`notarize.sh` uses an Apple notarytool keychain profile named `AC_PASSWORD` by default. Configure it once on the signing Mac:

```sh
cd <repo>/apple_native/JARVISCeremony
xcrun notarytool store-credentials AC_PASSWORD \
  --apple-id <apple-id> \
  --team-id T5AFHQ4L9C \
  --password <app-specific-password>
bash tools/notarize.sh
spctl -a -vvv -t exec "$PWD/.build/JARVISCeremony.app"
xcrun stapler validate "$PWD/.build/JARVISCeremony.app"
```

Set `NOTARY_PROFILE=<profile>` before running `tools/notarize.sh` to use a different stored profile.
