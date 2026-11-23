# Link Auth SDK for iOS

Swift package for **Login with Link**: let people sign in to your iOS app with their
Link account. The SDK opens the Link app for confirmation, verifies the result on the
device and keeps the session in the Keychain.

- `LinkAuth` is a Swift `actor` with `async`/`await` methods.
- OAuth 2.1 Authorization Code with PKCE (S256) and OpenID Connect.
- ID tokens are verified on the device: signature, issuer, audience, expiry and nonce.
- Sessions survive app restarts; tokens are refreshed and rotated automatically.
- No secrets in the app, and no third-party Swift dependencies.
- Typed errors you can branch on.

> Requires **iOS 13+** on arm64 (device and Apple-silicon simulator). Works from Swift 5
> and Swift 6 apps. Version **0.1.0** is the first public release; sign-in requires a
> current version of the Link app on the same device.

The protocol core is written in Rust and shipped as a prebuilt XCFramework. Its
sources, the Android library and the demo apps live in
[`auth-sdk`](https://github.com/linkmessengerme/auth-sdk).

## Install

In Xcode choose **File → Add Package Dependencies…** and enter:

```text
https://github.com/linkmessengerme/auth-sdk-swift
```

Or add it to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/linkmessengerme/auth-sdk-swift", from: "0.2.0")
],
targets: [
    .target(name: "App", dependencies: [.product(name: "LinkAuth", package: "auth-sdk-swift")])
]
```

## Quickstart

Register your app in Link Console and download its public JSON config
(`link_oauth_client_config`). It contains no secrets and can ship inside the app.

Create one instance per configuration and keep it for the lifetime of the app.
`redirectUri` must match a registered redirect URI exactly.

```swift
import Foundation
import LinkAuth

let auth = try await LinkAuth.create(
    configJson: configJson,
    redirectUri: "https://app.example.com/link/callback"
)
let status = try await auth.restore()       // once at startup

// On a button tap. Keep the Task in an app coordinator while the person is in Link.
let session = try await auth.signIn(scopes: ["openid", "profile", "offline_access"])
let user = session.user
let idToken = session.idToken

// In a separate handler for incoming URLs:
let callbackUser = try await auth.handleCallback(incomingURL)
// nil: a foreign or already handled callback. After process recreation a valid
// callback returns the identity even without a waiting signIn Task.

// Before a request to your backend, including after the app was restored:
let currentIdToken = try await auth.getIdToken()
let info = try await auth.getUserInfo()     // fresh data; the SDK supplies the token
let logout = try await auth.signOut()
try await auth.close()                      // releases the SDK; a stored session remains
```

These fragments run at different points of the app lifecycle, not in one Task:
`signIn` waits for a separate `handleCallback` call. Import `LinkAuthCore` when you
need the model, status and error-code types by name.

## Receiving the callback

Pass URLs from SwiftUI `.onOpenURL`, `scene(_:openURLContexts:)` and
`scene(_:continue:)` (`NSUserActivity.webpageURL` for Universal Links). On a cold
start, wait for `LinkAuth.create` and `restore()` before passing the saved incoming
URL. Do not call `restore()` while another operation is running.

For an HTTPS callback add `applinks:app.example.com` to Associated Domains and host an
`apple-app-site-association` file on that domain with your Team ID, Bundle ID and
callback path. For a custom scheme add URL Types to `Info.plist` and register the exact
URI in Console. The SDK does not configure your domain.

The authorization URL `https://linkm.me/oauth/authorize` is associated with the Link
app itself; your app only needs its own callback. Use `issuer`, `api_base_url` and
`token_url` exactly as they appear in the Console config.

`SystemLinkOpener` first tries Universal Links and then opens the URL through the
system, where a web page asks the person to open or install Link. Pass
`SystemLinkOpener(allowBrowserFallback: false)` to `LinkAuth.create` to get
`cannotOpenLink` instead when no app accepts the link. A successful open is not a
sign-in: the result arrives only after the callback and the tokens are verified.

## Scopes and user data

| Scope | Gives your app |
|---|---|
| `openid` | A stable user identifier (`sub`) for your project. Required. |
| `profile` | Name, username and avatar. |
| `offline_access` | A long-lived session that is refreshed without a new sign-in. |
| `phone` | The phone number, read through `getUserInfo()`. Requires approval in Console. |

`getUserInfo()` takes no scopes, user ID or token and never opens a consent sheet. The
result has `subject` and the optional `name`, `preferredUsername`, `picture`,
`phoneNumber` and `phoneNumberVerified`. A person can decline an optional `phone` and
still sign in; `phoneNumber` is then `nil`. Data is read again on every call and is not
stored by the SDK. Do not log it.

## Sign-in with your own backend

Your backend first creates and stores a one-time challenge with a cryptographically
random nonce (32 bytes, base64url). Pass the nonce to a **fresh** sign-in:

```swift
let session = try await auth.signIn(
    scopes: ["openid", "profile", "phone"], nonce: challenge.nonce)
// Send challenge_id, session.idToken and session.accessToken to your backend over HTTPS.
```

The backend consumes the challenge, verifies the ID token against the stored nonce with
a server SDK ([Go](https://github.com/linkmessengerme/console-sdk-go),
[Node.js](https://github.com/linkmessengerme/console-sdk-node),
[Python](https://github.com/linkmessengerme/console-sdk-python)), reads UserInfo for
the same `sub` and issues its own tokens. The phone number is never inside the ID token.

Without the `nonce` argument the SDK generates one. A custom nonce must be 32–256
base64url characters; anything else fails with `.invalidNonce`. An ID token obtained by
refresh carries no nonce, so `getIdToken(forceRefresh:)` does not replace a new
sign-in. End an existing session deliberately before signing in again.

## Device attestation

Link signs in only your genuine app on a verified device. The SDK creates an App Attest
key at the first sign-in and signs the code exchange and every token refresh with it,
which binds the session to the device.

1. In Xcode add the **App Attest** capability to your app target. Release builds need
   `com.apple.developer.devicecheck.appattest-environment` set to `production`.
2. Enter your **Team ID** for the application in Link Console. Development builds from
   Xcode are accepted only while development builds are allowed for the application.

App Attest needs iOS 14 and a real device. On iOS 13, in the simulator or without the
capability the sign-in is refused with `ErrorCode.attestationRequired`. Do not create
`LinkAuth` with `attestation: false`: Link refuses unsigned requests.
`session.user.deviceTrust` is `"verified"` for every signed-in user.

## Cancellation and errors

- `try await auth.cancelSignIn()` cancels a pending sign-in. Cancelling the Task that
  waits in `signIn` cleans up too. Do not cancel it because the app went to the
  background: opening Link itself moves your app to the background.
- Cancelling a Task that waits in `getSession` or `getIdToken` does not interrupt a
  shared refresh; its result is kept for the other callers.
- `LinkAuthFailure.protocolFailure(code)` carries a safe-to-log code such as
  `authorizationDenied`, `cancelled`, `expired` or `storage`. `cannotOpenLink` and
  `closed` are separate cases. A Task cancelled before an operation starts can throw
  `CancellationError`.
- A callback with a wrong `state` or issuer does not end the real attempt. A duplicate
  of a handled callback returns `nil`.
- `signOut()` disables the local session first. On `revocationPending` call it again
  once a connection is available.

`LinkSession` never exposes the refresh token. Do not log access or ID tokens or store
them outside the SDK.

## Example

A complete SwiftUI app — config import, sign-in, profile, refresh and sign-out — is in
[`auth-sdk/examples/ios-demo`](https://github.com/linkmessengerme/auth-sdk/tree/main/examples/ios-demo).

## License

[MIT](LICENSE)
