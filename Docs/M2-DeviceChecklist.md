# GoodMail M2: device checklist

What the package tests and the offscreen harness walkthrough can't show: real menus and windows, iOS (only
compile-checked here, no simulator), the system's own UI (Quick Look, share sheets, pickers, the scanner), background
execution, and Liquid Glass, which the offscreen renders leave out. Work through it on a Mac and an iPhone (an iPad
for the marked items) before M2 is called done.

Sources: plan §6.2, the P4/P5/P6 reports (commit messages on `main`), P7's own open points, the fixes after the
P7 review (m2/p7 70d844d) that only a device can show, and the unsubscribe row fix after the M2 acceptance run.

Setup: a Debug build. Most checks work in demo mode (`-demo YES`, no account needed); the ones marked **live**
need a Fastmail token with Email, Email submission and Masked Email. Expected results are in *italics*.

Not covered here, still open from the Fastmail probes (round 2): HOLDFOR and Undo against the live server, the
Scheduled mailbox, one-click unsubscribe on real list mail, and a sending identity for a mask. Until then GoodMail
keeps its safe defaults (`MaskedSendPolicy.usesDefaultIdentity = false`, `createsIdentities = false`, D13 "Sent during
the hold", D12 local-delay fallback).

---

## 1. Mac: menus and shortcuts

- [ ] File menu: **New Message ⌘N**, **New Viewer Window ⌥⌘N**, **New Masked Email ⌃⌘N**. *There is no separate
      File ▸ New Window, and no second New item for the compose windows.*
- [ ] ⌘N opens a composer window; it works while a composer window is in front, too.
- [ ] ⌥⌘N opens a second main window. *Known limitation: both windows share one selection (one `MailModel`), so
      choosing a mailbox in one shows it in the other.*
- [ ] Message menu: with a conversation open, **Reply ⌘R**, **Reply All ⇧⌘R**, **Forward ⇧⌘F** open composers for
      its newest message. *Disabled without a conversation.*
- [ ] In a composer, **Send ⇧⌘D** sends. *Disabled (menu greyed) while Send is off; with an address typed in To
      but not yet a token, ⇧⌘D still sends and the address is in the message.*
- [ ] Mailbox ▸ **Get New Mail ⇧⌘N** refreshes. *⌘R no longer refreshes.*
- [ ] In the Masked Email list, the + button and ⌃⌘N open the new-address sheet.
- [ ] With two main windows (⌥⌘N): ⌃⌘N opens the new-address sheet *only in the window in front*, and Sign Out…
      asks *only in the window it was chosen in*. ⌃⌘N is off while a composer window is in front.
- [ ] Format menu (TextFormattingCommands): in the composer's text, **⌘B / ⌘I / ⌘U** toggle bold, italic,
      underline, and the formatting bar's buttons follow the selection.
- [ ] File ▸ **Import from iPhone or iPad** (Take Photo, Scan Documents) with a composer in front: *the photo or the
      scan (PDF) arrives as an attachment chip.* Continuity Camera: *the sandbox needs no camera entitlement
      [UNVERIFIED].* (The paperclip menu has Choose File… and Photos…; Import from iPhone lives in the File menu only:
      SwiftUI offers no way to start it from a button.)

## 2. Mac: compose windows

- [ ] A composer is a window of its own (760×680), with Send (paperplane, glass, prominent) at the leading edge,
      then the paperclip menu and the Aa toggle, "New Message", "Reply" or "Forward" as the title and the save state
      as the subtitle ("Saved on this Mac", then "Saved to Drafts" about five seconds after typing stops). *Never
      the subject: macOS keeps window titles in its saved window state, a file outside the encrypted store (§0.11).*
      Check the Window menu, and that no subject appears in
      `~/Library/Containers/dev.goodmail.GoodMail/Data/Library/Saved Application State/` after a crash or a
      relaunch with restored windows.
- [ ] The formatting bar (glass capsule at the bottom) appears while the text has focus and the Aa toggle is on.
      *Glass renders; buttons act on the selection.*
- [ ] Send with the mouse while the To field still has an address typed (no Return): *the address is sent to.*
- [ ] Close the window with ⌘W: *the draft stays (Outbox ▸ Drafts on this Device until Fastmail has it, then in
      Drafts). An untouched new message leaves nothing behind.*
- [ ] Trash button: asks "Delete this draft?" when there is content; *the server copy goes to Trash.*
- [ ] **Window restoration:** with "Close windows when quitting an application" off in System Settings ▸ Desktop &
      Dock (or quitting with ⌥⌘Q), quit with a composer open that has text typed in the last second. *After
      relaunch the composer window comes back with everything, including the last keystrokes (quit saves for up to
      three seconds) and an address left typed in To (committed as a recipient at quit).*
- [ ] Quit (⌘Q) right after sending a message with a large attachment on a slow connection (or with Network Link
      Conditioner): *GoodMail quits within about three seconds, not when the upload ends; the message goes out
      after the next launch, and `tmp/Attachments` is empty after the quit.*
- [ ] A `mailto:` link in a quoted original (Show quoted text), a signature or a draft's preview: *a GoodMail
      composer opens, from the address the original came to; the system's mail app doesn't open.*
- [ ] Sign out with a composer window open, relaunch: *the restored window says "Sign in to GoodMail to continue
      writing" with Open GoodMail.* A window whose draft was sent or deleted meanwhile *closes by itself.*
- [ ] Composer windows as tabs (System Settings ▸ Desktop & Dock ▸ Prefer tabs: Always, or Window ▸ Merge All
      Windows): switch to another tab and back, keep typing. *The draft keeps saving* (a composer closes only when
      its view goes away, which a hidden tab or a minimised window must not count as).
- [ ] The Undo banner appears at the bottom centre of the main window, not the composer window.

## 3. iOS / iPadOS: the composer sheet

- [ ] The compose button sits in the thread list's bottom toolbar; the sheet opens large with Close (xmark) and
      Send (arrow.up, glass, prominent).
- [ ] Close with content asks **Delete Draft / Save Draft / Cancel**; Save Draft closes and keeps it. Close without
      content closes at once. *Swiping the sheet down keeps the draft too.*
- [ ] A reply opens with the keyboard in the text; a new message and a forward don't (tap To).
- [ ] **TextEditor grows inside the scroll view** with long text; the header scrolls away with it.
- [ ] **The glass keyboard toolbar:** while the text has focus it shows the formatting controls (B, I, U, S, Text
      Style, List, Link) and the paperclip; while a recipient field has focus, only the paperclip.
      `.textInputFormattingControlVisibility(.hidden, for: .inputAssistant)`: *no second set of system controls.*
- [ ] Link (keyboard toolbar): an alert to add or edit the link; *an entry that isn't a link asks again with the
      reason; confirming an unchanged mailto/tel link leaves it unchanged.*
- [ ] **List continuation:** Return after "• item" continues the list; Return on an empty item ends it.
- [ ] **Undo/redo** while typing and formatting (TextEditor bug 83650197, R-editor E19): *no lost or doubled text.*
- [ ] **Writing Tools** on a selection: Rewrite, and Make List. *Rich results keep only what mail can carry; lists
      arrive as "• " paragraphs.*
- [ ] Recipient fields: suggestions appear in a list under the field; `.textContentType(.emailAddress)` QuickType
      suggestions appear *even without Contacts access*.
- [ ] Hardware keyboard on iPad: ⌘N opens a composer sheet in the window in front; ⌘R/⇧⌘R/⇧⌘F/⇧⌘D work.
- [ ] Reading pane: Reply is one menu at the bottom (Reply, Reply All, Forward, Forward as Attachment); the More
      menu (…) has Forward as Attachment and, for list mail, Unsubscribe….
- [ ] After Send, the Undo banner floats above the bottom toolbar, *not over it* (64 pt inset, a guess).
- [ ] iPhone, offline, inside a conversation: reply and Send, then tap **Outbox** in the banner. *The Outbox list
      shows (with the waiting message), not an empty "Outbox" page; Back leads to the mailbox list.*
- [ ] Type an address in To without Return, then switch apps. *The draft saved then has it as a recipient (it is a
      token when you come back), also after iOS ended the app in the background.*

## 4. Attachments

- [ ] Paperclip ▸ **Choose File…** (several files at once) and **Photos…** (a photo and a video): *chips with
      upload progress; a video is read from a file, not into memory.*
- [ ] **iOS: Scan Document**: *the scanned pages arrive as one PDF named after the scan; the composer is still
      open afterwards and keeps saving what is typed* (the scanner is a sheet: a full-screen cover would take the
      composer off the screen, and a composer that disappears closes). Same for Photos… and Choose File….
- [ ] **Paste and drop into the text:** a Finder file / Files file, a screenshot, an image from Photos, a PDF.
      *Each becomes an attachment chip; no path or "￼" appears in the text; pasting text stays text.* (P6: the iOS
      routes are compile-checked only; dropped copies wait in `tmp/Dropped` for ten minutes.)
- [ ] A photo with location data: *the attached copy has no GPS tags (check with Preview ▸ Inspector or exiftool on
      the received mail).* A photo whose location can't be removed: *"Attach with Location?" asks first.*
- [ ] A composer chip whose upload failed ("Upload failed – tap to retry") or whose data is gone ("Re-attach"):
      *VoiceOver reads it as a button and offers Retry Upload / Attach Again… as an action; right-click (Mac) or a
      long press (iOS) shows Retry Upload / Attach Again… and Remove; with keyboard navigation on (Mac: System
      Settings ▸ Keyboard ▸ Keyboard navigation) Tab reaches the chip and Space retries.*
- [ ] Received attachments: tap a chip → **Quick Look** (iOS: share and markup work; Mac: the "Open with" button).
      *The chip shows a download ring the first time, then "available offline".*
- [ ] Mac: open a Quick Look preview, select another message, then close the panel. *The decrypted copy in the
      app's `tmp/Attachments` is gone ten minutes later, and at quit at the latest.* "Open with" another app within
      the ten minutes works.
- [ ] Context menu **Save…**: Mac save panel (also over an existing file, and on another volume such as a USB
      stick); iOS `fileExporter`. *The saved file is complete; on the Mac it carries the quarantine flag.* *No
      plaintext copy is left in the container's `tmp` or `Library/Caches` afterwards* (C32).
- [ ] Context menu **Share…** with an image attachment → **Save Image**: *iOS asks for Photos (add-only) access and
      saves; no crash* (C33). A PDF offers PDF targets.
- [ ] Mac: drag an attachment chip to the Desktop: *the file appears; the temporary copy goes after ten minutes.*
- [ ] Low Data Mode on: *no attachment prefetch.* Cellular without Low Data Mode: *small attachments (≤ 1 MiB) of
      the newest mail are prefetched* (D24).

## 5. Contacts

- [ ] First focus in a recipient field shows "Suggest people from Contacts [Allow]"; Allow brings up the system
      prompt once. *Afterwards the row is gone and contacts are suggested.*
- [ ] iOS with **limited access**: the last suggestion row is the system's `ContactAccessButton` for the typed
      text; *picking someone there makes them a suggestion.*
- [ ] A contact edited in Contacts while GoodMail runs is suggested with the new address (CNContactStoreDidChange).
- [ ] Mac: the sandbox prompt appears (ENABLE_RESOURCE_ACCESS_CONTACTS) and the usage text reads right.

## 6. Sending, Outbox, Undo (D12–D14, C2, C3)

- [ ] **live** Send to yourself: the banner "Sending “…”… Undo" counts down ten seconds; the message arrives about
      15 seconds after Send. *Received headers: From and Return-Path as chosen, Message-ID on the From domain, Date in
      UTC, no User-Agent or X-Mailer.*
- [ ] **live** Undo within ten seconds: *the composer comes back with everything, attachments included; nothing
      arrives.* (Probe round 2 decides whether Fastmail's hold works as assumed; until then D12's local delay is the
      fallback.)
- [ ] Airplane mode, Send: banner "Will send when you're back online · Outbox"; Outbox row "Waiting for
      connection" with Cancel, Edit, Delete. *Never "Sending…".* Back online: *it goes out within seconds.*
- [ ] Outbox while held: "Sending at about hh:mm:ss" with Cancel (until about 13 s after Send) and Delete (online
      only).
- [ ] Sidebar: the Outbox row appears only while something is in it, with a count; *red when something failed.*
- [ ] Failed message (e.g. a recipient Fastmail rejects): the row says why, with Edit, Retry, Delete.
- [ ] **live** A message that failed because the token can't send: its row says so with Replace Token…, Edit,
      Delete. *After Replace Token with a token that can send, it goes out by itself (Undo banner); a row in that
      state while the token can send offers Retry.*
- [ ] Drafts on This Device ▸ Delete (button and context menu): *asks "Delete …?" first; Cancel keeps the draft.*
- [ ] One-off notices (another device sent or cancelled, already sent) appear as glass toasts at the top and go
      after five seconds.

## 7. iOS background sending

- [ ] **live** Send with a 20 MB attachment and leave the app at once: *the system's continued-processing UI shows
      "Sending “…” – Uploading attachments" with progress, and the mail arrives.* Registration uses a fresh concrete
      identifier `dev.goodmail.GoodMail.send.<UUID>` per send, under the Info.plist's `send.*` wildcard: *check that
      iOS accepts it* [UNVERIFIED]. (The plan's `send.<draftID>` would register the same identifier twice when a
      message is sent again after Undo, which iOS answers by killing the app.)
- [ ] **live** Queue offline, lock the phone, come back online without opening GoodMail: *whether the app-refresh or
      the processing task sends it later* (the system decides when; check the Outbox afterwards, and Settings ▸
      General ▸ Background App Refresh).
- [ ] Going to the background with a composer open: *the draft is saved on the device and to Fastmail.*
- [ ] **live** Send with a 3–4 MB attachment (below the 5 MB continued-processing threshold) on a slow uplink and
      leave the app at once, so that iOS suspends GoodMail before the upload ends. *The refresh and processing
      requests were made anyway (they are made before the saves and the Outbox pass): the message goes out later
      without opening GoodMail.* In the debugger:
      `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"dev.goodmail.GoodMail.outbox-processing"]`
      runs the processing task on demand.
- [ ] After backgrounding with a Quick Look preview closed, the decrypted copy is gone (released copies purge).

## 8. Masked Email (D19–D22, Q3)

- [ ] **live** Reply to mail that reached a masked address *that is one of your sending addresses* (Fastmail ▸
      Settings ▸ My email addresses): From is the mask without a name, no signature; *it sends; received headers show
      only the mask (From and Return-Path).*
- [ ] **live** Reply from a mask that is *not* a sending address: *Send is off, with "Fastmail only lets apps send
      from a masked address that is a sending address. Add … under Fastmail → Settings → My email addresses."; no
      dialog asks to create an identity; the message stays a draft.*
- [ ] Reply from a disabled mask: yellow warning with **Enable Address**; *enabling it clears the warning.*
- [ ] From menu: identities, then "Masked Addresses…" (searchable; those without a sending identity marked "No
      sending identity").
- [ ] Masked Email detail ▸ **New Message from This Address**.
- [ ] A `mailto:` link in a message delivered to a mask: *the composer opens from that mask (C8).*

## 9. Unsubscribe

- [ ] List mail: the privacy bar shows "Mailing list · Name" with Unsubscribe; the dialog says the list sees the IP
      address (one-click), or names recipient and sender (mailto), or opens the private page (web).
- [ ] **live** One-click on real list mail (once probe round 2 confirms Fastmail's verdict format): *"Unsubscribe
      requested – lists can take a few days to stop."* Later: "Unsubscribe requested on <date>".
- [ ] Web-only list: the private sheet loads the page; Open in Safari works; *nothing it stores survives the sheet.*
- [ ] Mail to a mask also offers **Disable Masked Address Instead**; afterwards the row says it is disabled.
- [ ] Junk or phishing mail: *no unsubscribe row.*
- [ ] Reading-pane More menu and the list's context menu ▸ Unsubscribe… open the same row in a sheet. *A small
      progress indicator shows until Fastmail answers; a list whose links GoodMail can't use (say a plain http://
      link) gets "This list doesn't offer a way to unsubscribe that GoodMail can use." instead of an empty box.*

## 10. Account and data safety

- [ ] **live** Sign in with a token *without* Email submission: reading works; the composer says "Your API token
      can't send mail…" with **Replace Token…**. Replace it with a token that has Email submission: *Send turns on in
      the open composer; the token is stored in the Keychain (still signed in after relaunch).*
- [ ] **live** Replace Token with a token of another account: *refused: "This token belongs to another Fastmail
      account…"; nothing changes.*
- [ ] Sign Out… with a message waiting (offline): *"1 message hasn't been sent. Signing out deletes it." with Sign
      Out and Delete, Show Outbox, Cancel.* Show Outbox opens the Outbox; Sign Out and Delete deletes the account's
      data and every decrypted attachment copy.
- [ ] **live** Sign Out… within ten seconds of a Send (held for Undo): *"1 message is being sent and may still go
      out after you sign out." with Sign Out (not "and Delete"); the message arrives.* Cancelling it in the Outbox
      first keeps it from going out.
- [ ] **live** Revoke the token in Fastmail while a message waits (offline), so that GoodMail returns to sign-in;
      then sign in with a token of *another* account. *"Delete Mail of the Other Account?" names the waiting
      message; Cancel keeps it (signing in with the first account's new token sends it), Sign In and Delete
      deletes it.*
- [ ] Sign out while a large attachment downloads (Quick Look on a big file): *no decrypted copy appears in
      `tmp/Attachments` afterwards.*
- [ ] Offline cold start (airplane mode, launch): *composing and queueing work with the last known identities.*
- [ ] A store that can't be opened (e.g. replace `Mail.sqlite` in the container with a copy of another file):
      *one-time alert "GoodMail couldn't open its local copy and started a new one. The old copy is kept."; the old
      files are in `Application Support/GoodMail/Unreadable/<timestamp>/`.* The alert also shows after a relaunch
      if GoodMail ended before showing it.
- [ ] A store that can't be opened *for now* (e.g. `chmod 000` on `Mail.sqlite` in the Mac container, or a full
      disk): *"GoodMail Can't Open Your Mail … Nothing was deleted." with Try Again, not the sign-in screen; nothing
      moves to `Unreadable/`; Try Again (or coming back to the app) opens the mail once the cause is gone.*
- [ ] Mac quit with Quick Look copies open: *`tmp/Attachments` is empty afterwards.*

## 11. Look and feel (Liquid Glass, §5.1)

- [ ] Glass only on toolbars, the formatting bar, the Send button, the Undo banner, the Outbox pill and the toasts;
      message bodies, recipient tokens, attachment chips, the unsubscribe row and composer notices are plain content.
- [ ] Light and dark mode: the composer's signature and quote follow the appearance when they carry no styling of
      their own; styled mail keeps its white page.
- [ ] Narrow Outbox column on the Mac and iPhone: *the row's buttons move under the text instead of truncating.*
