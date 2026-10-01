# GoodMail

An open-source, privacy-first mail client for [Fastmail](https://www.fastmail.com), native on iOS and macOS (SwiftUI).

> Status: early development (milestone M0: foundations). Not usable yet.

## Goals

- **Built for Fastmail.** Uses JMAP directly, no IMAP. First-class **Masked Email**: create, send from, disable and delete masked addresses without leaving the app.
- **Privacy first.** Remote content and tracking pixels are blocked by default, tracking parameters are stripped from links, the local cache is encrypted, and the app has an optional Face ID / Touch ID lock. No analytics, no third-party SDKs, and no servers of ours in the middle.
- **One-tap unsubscribe** via `List-Unsubscribe` / RFC 8058 one-click.
- **Fast search and filtering.** Instant local full-text search merged with server-side search, plus saved searches.
- Everything else a good mail client needs: threads, swipe actions, keyboard shortcuts, offline actions, and undo.

## Roadmap

| Milestone | Scope |
|---|---|
| M0 | Foundations: JMAP client (`JMAPKit`), app scaffold, API-token onboarding, CI |
| M1 | Read & triage, Masked Email management, tracker blocking, encrypted cache, search |
| M2 | Compose (incl. sending from masked addresses), drafts, attachments, unsubscribe |
| M3 | Rules & filters, snooze, notifications, widgets, Shortcuts, accessibility |
| M4 | OAuth, multiple accounts, optional self-hostable push relay |
| M5 | OpenPGP |
| M6 | S/MIME |

## Project layout

```
project.yml           XcodeGen spec for the iOS + macOS app (the .xcodeproj is generated, not committed)
App/                  SwiftUI app: onboarding, screens, Keychain
GoodMailKit/          Swift package holding all non-UI logic
  Sources/JMAPKit/    JMAP protocol layer (RFC 8620/8621 + Fastmail Masked Email)
```

## Development

Requires Xcode 16+ (Swift 6). Minimum deployment targets are iOS 18 and macOS 15.

```sh
brew install xcodegen
xcodegen generate          # creates GoodMail.xcodeproj
open GoodMail.xcodeproj

cd GoodMailKit && swift test   # run the package tests
```

### Code signing

Out of the box the Mac app is ad-hoc signed, so it builds without an Apple developer account. Such builds
keep the API token in the login keychain, and macOS asks for your login password again after each rebuild.

To sign with your own team (a free Personal Team works), create `Config/Signing.local.xcconfig`, which is
git-ignored, and run `xcodegen generate` again:

```
DEVELOPMENT_TEAM = <your team id>
CODE_SIGN_IDENTITY[sdk=macosx*] = Apple Development
CODE_SIGN_ENTITLEMENTS = Config/TeamSigned.entitlements
```

Team-signed builds store the token in the data protection keychain, as on iOS.

### Signing in

GoodMail signs in with a Fastmail **API token** for now (OAuth comes later). Create one under
*Settings → Privacy & Security → Integrations → API tokens* and give it the **Email** and **Masked Email** scopes.
The token is kept in the Keychain on your device only.

## License

MIT. See [LICENSE](LICENSE).
