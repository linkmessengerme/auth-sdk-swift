# Changelog

## 0.2.0 — unreleased

Device attestation. Requires a Link server that advertises it; with any other server
the SDK behaves as 0.1.0.

- An App Attest key per installation, attested once at the first sign-in; it
  survives sign-out.
- The code exchange and every token refresh are signed by this key, which binds the
  session to the device.
- A signed refresh whose answer was lost is repeated instead of ending the session.
- `UserIdentity.deviceTrust`: the `device_trust` claim of the ID token.
- New error code `attestationRequired`.
- `LinkAuth.create(..., attestation: false)` turns attestation off.
- iOS 13, the simulator and App Attest failures sign in without a key; the server
  decides.
- Apps need the App Attest capability and a Team ID in Link Console.

Notes for upgrading:

- No code changes are required. `ErrorCode` has a new case; add it to exhaustive
  `switch` statements.
- A custom `SecureStorage` must accept a second record name,
  `link.attest.v1.<digest>`, next to `link.auth.v1.<digest>`.
- A session with an attested key cannot be read by 0.1.0; sign in again after a
  downgrade.

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
