# Changelog

## 0.2.0 — 2026-11-23

Device attestation, built from
[`auth-sdk` 0.2.0](https://github.com/linkmessengerme/auth-sdk/releases/tag/v0.2.0).

- An App Attest key per installation, registered once before Link is opened for the
  first sign-in. The code exchange and every token refresh are signed by it, which
  binds the session to the device.
- A signed refresh whose answer was lost is retried under the next attempt number.
- `UserIdentity.deviceTrust` (the ID token's `device_trust` claim) and the
  `AttestationRequired` error code.
- `LinkAuth.create(..., attestation: false)` turns attestation off.
- Add the App Attest capability to your target and enter your Team ID in Link
  Console. The simulator never attests.
- Custom `SecureStorage` implementations must accept a second record name,
  `link.attest.v1.<digest>`.

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
