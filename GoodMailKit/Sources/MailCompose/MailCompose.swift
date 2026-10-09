// The message being written: its rich text, the HTML and plain text it turns into, replies and forwards.
//
// - `MessageDraft` is one composition, independent of any view; its body is an `AttributedString` in
//   `MailBodyFormatting`'s scope, the same type `TextEditor(text:selection:)` and App Intents' `.mail.createDraft`
//   use. The editing commands are pure functions on that string and the editor's selection (BodyEditing.swift).
// - `MailHTMLWriter` and `MailBodyHTMLReader` convert between editor text and HTML. Untrusted HTML only ever
//   reaches the reader through MailPrivacy's `OutgoingHTMLSanitizer`, never a system HTML importer.
// - `ReplyBuilder`, `MessageAssembler` and `DraftParser` turn originals into replies and forwards, drafts into
//   the bodies sent to Fastmail, and saved drafts back into drafts.
//
// SwiftUI is imported for the text attributes (fonts, colours) and font resolution only; everything here works
// off the main actor. Sending, saving and storage live in GoodMailCore and MailStore, which this module doesn't
// know about.
