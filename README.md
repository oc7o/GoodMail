# GoodMail

An open-source, privacy-first mail client for [Fastmail](https://www.fastmail.com), native on iOS and macOS (SwiftUI).

> Status: early development. M1 is done: you can read, triage and search mail, online and from the
> encrypted local copy, save searches, and manage Masked Email. M2's composing works too: rich text, replies and
> forwards, drafts, attachments, sending from masked addresses, an offline Outbox with Undo Send, and unsubscribe.

## Goals

- **Built for Fastmail.** Uses JMAP directly, no IMAP. First-class **Masked Email**: create, send from, disable and delete masked addresses without leaving the app.
- **Privacy first.** Remote content and tracking pixels are blocked by default, tracking parameters are stripped from links, the local cache is encrypted, and the app has an optional Face ID / Touch ID lock. No analytics, no closed-source SDKs, and no servers of ours in the middle.
- **One-tap unsubscribe** via `List-Unsubscribe` / RFC 8058 one-click.
- **Fast search and filtering.** Instant local full-text search merged with server-side search, Fastmail-style operators (`from:` `to:` `cc:` `subject:` `body:` `in:` `is:unread` `is:flagged` `has:attachment` `before:` `after:`), plus saved searches.
- Everything else a good mail client needs: threads, swipe actions, keyboard shortcuts, offline actions, and undo.

## Roadmap

| Milestone | Scope |
|---|---|
| M0 | Foundations: JMAP client (`JMAPKit`), app scaffold, API-token onboarding, CI |
| M1 | Read & triage, Masked Email management, tracker blocking, encrypted cache, search |
| M2 | Compose with rich text (incl. sending from masked addresses), drafts, offline outbox with Undo Send, attachments, unsubscribe, Contacts autofill, Writing Tools, Liquid Glass |
| M3 | Apple integration: Siri & Apple Intelligence (App Intents), Spotlight, Shortcuts, Handoff |
| M4 | Rules & filters, snooze, notifications, widgets, accessibility |
| M5 | OAuth, multiple accounts, optional self-hostable push relay |
| M6 | OpenPGP |
| M7 | S/MIME |

## Project layout

```
project.yml           XcodeGen spec for the iOS + macOS app (the .xcodeproj is generated, not committed)
App/                  SwiftUI app: onboarding, screens, Keychain
GoodMailKit/          Swift package holding all non-UI logic
  Sources/JMAPKit/      JMAP protocol layer (RFC 8620/8621 + Fastmail Masked Email)
  Sources/MailPrivacy/  Tracker removal, link cleaning, the locked-down HTML that messages render as, and the
                        allowlist sanitizer for HTML that leaves the device
  Sources/MailCompose/  The message being written: rich text, the HTML and text it becomes, replies, forwards
  Sources/MailStore/    Encrypted local copy of the account (SQLCipher) with a full-text index
  Sources/GoodMailCore/ Sync between server and store, and the app state behind the screens
  Sources/DemoAccount/  In-memory fake Fastmail account with sample mail
Vendor/GRDBSQLCipher/ GRDB built against SQLCipher (see Dependencies)
```

## How mail is stored

Mail is kept in a SQLCipher database in the app's container. Its 256-bit key is random, lives only in the
device Keychain and never syncs, so the file is useless anywhere else; signing out deletes both. The store is
a cache: stored emails are kept in step with Fastmail through JMAP change sync, older mail is filled in
in the background, and bodies of recent mail are fetched ahead so they open offline. Search asks the local
full-text index first and merges in Fastmail's results.

## Dependencies

| | Used for | License |
|---|---|---|
| [GRDB](https://github.com/groue/GRDB.swift) | SQLite toolkit | MIT |
| [SQLCipher](https://github.com/sqlcipher/SQLCipher.swift) | Database encryption | BSD-style |

GRDB only works with SQLCipher through an edited package manifest. Instead of a fork, `Vendor/GRDBSQLCipher`
holds that manifest next to an unmodified, pinned upstream checkout (a git submodule). SQLCipher itself comes
as the prebuilt framework published by its maintainers, pinned to an exact version.

## Development

Requires Xcode 27 (Swift 6.4). Minimum deployment targets are iOS 27 and macOS 27.

```sh
git clone --recurse-submodules https://github.com/oc7o/GoodMail.git   # or: git submodule update --init
brew install xcodegen
xcodegen generate          # creates GoodMail.xcodeproj
open GoodMail.xcodeproj

cd GoodMailKit && swift test   # run the package tests
```

### Demo account

Debug builds can run without a Fastmail account: pass the launch argument `-demo YES` (in Xcode under
*Product → Scheme → Edit Scheme → Run → Arguments*) to get an in-memory account with sample mail.
Nothing in it touches the network except the sample newsletter's image, and only after you press *Load Images*.

### Device checks

The package tests and an offscreen walkthrough of the demo account cover most of the app, but some things only show
on a real Mac or iPhone: menu shortcuts, compose windows coming back after a relaunch, the iOS editor and its keyboard
toolbar, sending in the background, Quick Look, the document scanner, Continuity Camera and the Contacts permission.
The M2 device checklist lists these checks; they are done by hand before a release.

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

GoodMail signs in with a Fastmail **API token** for now (OAuth comes later). Create one in Fastmail under
*Settings → Privacy & Security → Connected apps & API tokens → Manage API tokens*
(https://app.fastmail.com/settings/security/tokens) and give it the **Email**, **Email submission** and **Masked Email**
scopes. Without Email submission you can read, triage and write drafts, but not send. The token is kept in the Keychain
on your device only.

## License

MIT. See [LICENSE](LICENSE).
