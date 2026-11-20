# Releasing

Use `Link Messenger <dev@linkmessenger.me>` for Git authors, committers and
taggers. Publish through the Link Messenger account. Review source, history and
the built XCFramework for personal names, local paths and credentials.

The package is produced from [`auth-sdk`](https://github.com/linkmessengerme/auth-sdk).

1. In `auth-sdk`, run the release checks and `scripts/build-apple.sh`.
2. Copy `platforms/apple/Sources/LinkAuthAdapters` to `Sources/LinkAuth` and
   `platforms/apple/Generated/LinkAuthCore` to `Sources/LinkAuthCore`.
3. Zip the framework and compute its checksum:

```sh
cd platforms/apple/Artifacts
zip -r -X -y LinkAuthCoreFFI.xcframework.zip LinkAuthCoreFFI.xcframework
swift package compute-checksum LinkAuthCoreFFI.xcframework.zip
```

4. Update the release URL and the checksum in `Package.swift`, and date the changelog.
5. Commit, tag `vX.Y.Z` and create a GitHub release with the zip attached under the
   exact file name used in `Package.swift`. Existing tags and assets are never replaced.
6. Resolve and build the package from its public URL in a clean consumer project.
