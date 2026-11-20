# Changelog

## 0.1.0 — 2026-11-20

First public release.

- `LinkAuth` actor: `create`, `restore`, `signIn`, `handleCallback`, `getSession`,
  `getIdToken`, `getUserInfo`, `cancelSignIn`, `signOut` and `close`.
- Authorization Code with PKCE (S256) and OpenID Connect, with the consent shown in
  the Link app; ID tokens are verified on the device.
- Sessions and pending sign-ins restored from the Keychain after a restart.
- Refresh with token rotation, shared between concurrent callers.
- Optional backend nonce for sign-in with your own backend.
- URLSession transport, Keychain storage and a system opener with an optional
  Universal-Links-only mode.
- Prebuilt core for iOS arm64 devices and Apple-silicon simulators.
