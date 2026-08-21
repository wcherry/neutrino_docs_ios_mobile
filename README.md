# Neutrino Docs iOS

A secure, offline-capable document editor for the Neutrino ecosystem. Built with SwiftUI,
the app reuses Neutrino Drive as its storage layer and the existing Neutrino Auth and E2EE key
services rather than inventing its own.

## Tech Stack

- Swift / SwiftUI, iOS 16+
- Xcode / XcodeGen
- [swift-sodium](https://github.com/jedisct1/swift-sodium) — XChaCha20-Poly1305, `crypto_box_seal`

## Phase 1 (MVP) Status

Every Phase 1 feature in [agent_docs/mvp.md](agent_docs/mvp.md) is implemented.

| Area | Features | Status |
|------|----------|--------|
| Authentication | Login, refresh tokens, logout, device registration | COMPLETE |
| Encryption | Import key (file, paste, or QR scan), Keychain storage, Face ID / Touch ID unlock, automatic key loading | COMPLETE |
| Drive Integration | Home, Recent, Favorites, Shared, folder navigation; open, create, rename, delete, move, duplicate | COMPLETE |
| Document Viewer | Headings, lists, tables, blockquotes, code blocks, images, links, checklists | COMPLETE |
| Document Editor | WYSIWYG editing, auto-save, undo, redo, find, replace | COMPLETE, less the preview toggle |
| Synchronization | Manual sync, auto-sync, conflict detection, background upload/download | COMPLETE |
| Offline Mode | Cache open/recent/favorite documents; queue pending saves, deletes, moves | COMPLETE |
| Version History | Previous versions, restore, timestamps | COMPLETE |
| Settings | Theme, font size, editor font, auto-save interval, sync settings | COMPLETE |

## Phase 2 (Better Editing) Status

| Area | Features | Status |
|------|----------|--------|
| Rich content | Tables, task lists, code blocks, images, front matter | COMPLETE — callouts, Mermaid and math went with the Markdown viewer |
| Editor Improvements | Smart indentation, auto bullets, auto numbering, auto closing brackets, keyboard shortcuts, code folding | COMPLETE except multi-cursor |
| Style Bar | Paragraph style (Body, H1–H3), alignment (left/center/right/justify); bold, italic, link, image, code, quote, table, checkbox, lists, indent | COMPLETE |
| Document Outline | Heading navigation, collapse sections, search headings | COMPLETE |
| Split View | Editor and preview side by side on iPad | DROPPED — there is no preview to put beside the editor |
| Live Preview | The document is styled in place, always | COMPLETE — there is nothing else to preview |

**Images are drawn in the editor, not described.** Concealing only an image's punctuation left
`![A cat](…)` reading as "A cat" — the alt text sitting where the photograph should be. A line that
is nothing but an image is now concealed *whole*, the layout manager gives its line fragment the
height of the picture, and `EditorTextView` draws the picture into that space. An image among words
stays an inline link: a paragraph cannot reflow around something the height of a photograph. Sizes
come from `EditorImageStore`, which downloads and decrypts a Drive reference in the background and
asks for another layout pass when it arrives — layout runs on every keystroke and cannot fetch or
decode anything.

**The pictures are drawn in a subview, not in the text view's layer.** A `UITextView` keeps its text
in a private subview, and a subview is always in front of its parent's own drawing — so anything the
editor painted itself could only ever be *behind* the words. It also does not follow the scroll:
scrolling a scroll view moves the bounds over the content and does not, by default, repaint, so a
decoration stayed at the screen position it was first painted at while the document slid out from
under it. Together those are one symptom — a picture that sits still while text moves across it.

`ImageOverlayView` has neither problem. It is a subview positioned in *document* coordinates, so the
scroll view moves it, and it is inserted above the text, so nothing draws over a picture. The
remaining decorations — code panels, bullets, quote bars, fold chevrons — are still painted by the
text view and rely on `needsDisplayOnBoundsChange` to follow the scroll, which costs a repaint per
frame; that is why the geometry pass behind them measures only the glyphs on screen and a screenful
either side rather than walking the whole document.

**A document stores a reference to a picture, never the picture.** The body carries
`neutrino-drive:<fileId>` where an image source goes (`DriveImageReference`), and the bytes are a
Drive file like any other — encrypted under a key of its own, resolved at draw time by downloading
and decrypting it. That is the only thing that *can* work: Drive is end-to-end encrypted, so a Drive
URL serves ciphertext no image view could render. The spelling is shared with the web app's
`driveImageRef` (`web/apps/web/src/lib/driveImages.ts`); both apps read and write the same file.

**Inserting an image is a picker, not a placeholder.** The image button opens a sheet with three
sources — Photos, a link, or a picture already in Neutrino Drive — and shows what was chosen before
it goes in. Every source has to end up a Drive file. One already is: a picture chosen from Drive is
referenced where it stands, with no upload and no re-encode, so the same photograph used in ten
documents is stored once. A photo, a local file, or a linked address is uploaded into
the account's `Attachments` folder — the same folder the backend seeds at registration and the web
app get-or-creates, so all three have to spell it the same way. The upload happens on Insert rather
than on preview: a picture staged and then abandoned would otherwise leave a file nothing mentions.

Because originals are stored, Insert sends megabytes. The wait is therefore measurable rather than a
bare spinner — the sheet shows bytes sent against the total, offers Cancel, and keeps the staged
picture when an upload fails so the button becomes "Try Again" instead of sending somebody back to
the photo library. Cancelling costs nothing server-side: a file record is only written by the request
carrying the bytes, so an unfinished upload leaves nothing to clean up. It is deliberately *not*
backgrounded — the document stores the file id, and only the upload response knows it, so there is
nothing to write into the document until the transfer completes.

**The original is what gets stored.** The bytes go up as they arrived, at the resolution and in the
format the user chose, exactly as the web app does — Drive holds the picture somebody actually has
rather than this app's idea of a reasonable one. HEIC is the one exception: it is what an iPhone
camera writes and what most browsers cannot display, so it is converted to JPEG at full resolution,
because a picture stored as it came would render here and nowhere else.

Storing originals is only affordable because of the other end. `UIImage(data:)` holds the whole
picture in memory to draw a thumbnail of it — about 48MB of bitmap for a 12-megapixel photograph, so
a document showing five would be killed for the memory before it finished drawing.
`EditorImageStore.image(from:)` decodes through ImageIO at a bounded size instead, so the cost is
the size on screen rather than the size on disk. Downscaling before upload would have thrown those
pixels away for good; downsampling at decode only declines to hold them.

**Documents written before this still open.** An `http(s):` URL or an inline `data:` URI is left
exactly as it is and still renders, matching what the web app does. This app no longer writes either
form, but it reads both, so an older document is not silently rewritten by being opened.

Browsing Drive for a picture is also the first listing this app makes that is not `type=doc` — the
server's `type=photo` filter is what it has been filtering *out* everywhere else.

**Tapping a picture opens its properties**, because a picture is one atomic node and so the only
thing on the line there is to tap. The panel is the web's `ImagePropertiesModal` in the shape of
a phone: Layout (width, position), Appearance (border, shadow), Tint (brightness, contrast,
saturation), Metadata (alt text, title, caption), with a live preview of the settings and nothing
written until Done — a panel that saved every slider movement would fill the undo stack and send an
autosave per frame.

The attributes are the web's, exactly: `AdvancedImageExtension` adds `width`, `alignment`, `caption`,
`border`, `shadow` and `imageFilter` to the image node, and a second vocabulary would mean two apps
disagreeing about one document. `ImageAttributes` reads and writes those attributes on the node
itself — the editor holds the same tree the web app stores, so there is no spelling to invent and
nothing to lose in translation. Anything this app has never heard of rides through in `other`, so a
later web release can add an attribute without phones deleting it.

Two deliberate divergences from the web. An image with no alignment is drawn **left**, matching the
web's CSS, where this editor used to centre everything. And a float is drawn as the ordinary
alignment on the same side: text cannot flow around a picture that is a line of its own, so the
attribute is preserved and the web still floats it. An explicit width also overrules the 260pt height
cap — that cap is a default for photographs nobody has said anything about, not a rule.

**Alignment is the node's own attribute.** The web editor aligns headings and paragraphs with
TipTap's `TextAlign`, stored as `textAlign` on the node, and `DocumentAlignment` reads and writes
exactly that. The projection turns it into a paragraph style — merged into the block's own style
rather than replacing it, so a centred heading keeps the air above it and a centred list item keeps
its indent. Left is the absence of the attribute rather than a value of its own: it is the default
in both apps, and a document nobody has aligned should not carry a setting saying so.

**On a phone every editor control is in the style bar, and the whole bar scrolls.** The navigation
bar keeps the document's name and the way back; Outline, Undo/Redo, Find, folding, Version History
and the offline toggle moved into a `⋯` menu in the row. Nothing is pinned to either edge — pinning
the ends is what makes a bar crowded, because it leaves every addition fighting over a shrinking
middle. A new control costs one place in the row and takes width from nothing already there. Order
is priority order, since what is visible without scrolling is whatever comes first. Regular width is
untouched for now and keeps its navigation-bar items.

**The style bar rides with the keyboard.** It is the text view's `inputAccessoryView`, not a
SwiftUI `.keyboard` toolbar item — that placement only finds SwiftUI's own text inputs, so it never
appeared over the `UITextView` inside the representable. As an accessory view it animates with the
keyboard and needs no keyboard-frame arithmetic. It is only half the story: an accessory view exists
only while something is first responder, and once the bar holds Version History and Outline, an
action reachable only by first tapping into the text is not reachable. `DocEditorView` therefore
docks the same view at the bottom whenever the keyboard is down — two copies of one view, never both
on screen, switched by the controller's `isEditing`. The paragraph style leads it, and is the one control with no other way in: `# ` still
makes a heading, but with the marker concealed there is nothing on screen to say which level a line
is, so the menu both reports the caret's style and changes it (⌘0–⌘3).

**There is no preview, and no edit mode either.** The roadmap asked for a preview toggle and, on
iPad, a split view; both were built and both are gone. A mode switch only earns its place while the
editing surface shows something other than the document, and this one does not: `# ` is how a
heading is *typed*, not how it is displayed. Two of Phase 2's deliverables therefore ship as one
surface rather than three, and what the roadmap called Live Preview is now simply what a document
looks like. Version History previews an old revision through the same editor with editing switched
off — one projection, read-only, rather than a second renderer to keep in step.

**Multi-cursor is not implemented.** `UITextView` supports exactly one insertion point, and neither
TextKit 1 nor TextKit 2 exposes a way to add another — multiple carets would mean replacing the text
system with a custom engine (own layout, selection model, input handling, and accessibility), which
is a larger undertaking than the rest of Phase 2 combined. Every other item on the Phase 2 list is
done.

## Phase 5 (Search) Status

| Area | Features | Status |
|------|----------|--------|
| Local Search | Indexed titles, content, headings, tags | COMPLETE |
| Global Search | Across Drive; owner, folder, modified, and tag filters | COMPLETE with a caveat — see below |
| Saved Searches | Named query plus filters, kept encrypted | COMPLETE |

### Why the index is on the device

Drive has a search endpoint and this app uses it, but it can only match **file names**. The server's
full-text table is filled by a `content-index` endpoint that takes plaintext, and calling it would
mean handing the server the decrypted text of every document — giving up the end-to-end encryption
the rest of the app is built around. So body text, headings and tags are indexed locally, from
documents this device has already decrypted, and the server is asked only about names.

That is the caveat on Global Search: it reaches every document in the drive, but a document the
index has not read yet can only be matched on its name, and the result row says so. Because a server
hit carries no tags or folder ancestry, hits are dropped rather than guessed at while a tag or folder
filter is set.

`SearchIndex` is the inverted index and is pure — the tokenizing, prefix matching, scoring and
filters are all asserted directly. Query terms are treated as **prefixes** combined with **AND**, and
terms under three characters are dropped, matching the web app's engine (`@neutrino/search`) so a
query means the same thing on both clients. Field weights are title 3, heading 2, tag 2, content 1;
the web app has only title and content, and headings and tags are given their own fields here because
the roadmap asks for them by name.

### What is indexed, and when

A document is indexed when it is **opened or saved** — its plaintext is already in hand, so it costs
a tokenize pass and no network. Everything else is reached by the crawl, which walks the drive and
downloads what it has not seen. The crawl is started from the Search tab rather than automatically on
launch: it downloads and decrypts every document the account can read, which is a real amount of
network and battery to spend without being asked.

The index deliberately does **not** store document text — only terms, the title, tags, and a 240
character preview. An index of terms is already a bag of words, but keeping the prose verbatim would
make the index a second complete copy of every document.

### The index at rest

`index.bin` and `searches.bin` are sealed with XChaCha20-Poly1305 under a key generated once and kept
in the Keychain as `AfterFirstUnlockThisDeviceOnly`, the same protection as the E2EE key pair. The
index key is **not** the user's E2EE key and never leaves the device: it protects a local derivative
of documents the user can already read. Signing out destroys the index, the saved searches, and the
key — the index holds text decrypted from that account's documents and cannot outlive the session.
A file that cannot be decrypted (missing key, corruption) is discarded and rebuilt rather than failing
the load on every launch.

Saved searches live under the same key rather than in `UserDefaults`, because a query is a statement
about what someone is looking for in their own documents and is not something to leave in a plist
that any backup picks up.

### Rich content notes

**Front matter** is a document's metadata block, kept as a tagged `yaml` code block — the web app's
spelling, so it survives a round trip through either editor. `FrontMatter` reads it as flat
key/value pairs (scalars, inline lists, dash lists); `title` and `tags` are the two keys with a
defined meaning, and the search index reads both. This is deliberately a small YAML subset, not a
YAML engine.

**Callouts, Mermaid diagrams and math** were rendered by the Markdown viewer and went with it. Their
nodes still survive a round trip untouched — an unmodelled node is written back exactly as it
arrived — so a document that has them is not damaged by being opened here; it simply does not draw
them yet.

### Editing notes

The formatting commands and typing behaviours are pure functions over an `EditorDocumentState`
(attributed text plus selection), which is what makes them testable without a live text view. Code folding suppresses
glyphs and zeroes line fragments through an `NSLayoutManagerDelegate`, leaving the text storage
untouched — so the binding, autosave, and undo always see the whole document and editing a folded
document cannot corrupt it. That is also why the editor builds a TextKit 1 stack explicitly: folding
needs per-fragment geometry that TextKit 2 does not expose.

**There are no line numbers.** They were on the Phase 2 list and were built, then removed: a gutter
of numbers is a source-code affordance, and once the editor renders a document as a document it
reads as a leftover from the wrong kind of editor. What survives of the gutter is a 16pt margin
holding the fold chevrons — constant width, so a document does not shift sideways the moment it
gains its first foldable region.

**There is no syntax to hide, because there is no syntax.** `DocumentProjection` flattens the tree
into styled text and `DocumentBuilder` reads it back; every character carries the block it belongs
to and the marks on it, and the two passes are inverses. A heading is large because it is a heading
node, a bullet is drawn because its block says it is a list item. Typing `# ` still *makes* a
heading — see `DocumentInputRules` — and the characters are consumed as the block changes, so
nothing is left on screen for the caret to trip over.

That is what removes a whole class of bug rather than solving it: with no invisible markers there
are no offsets that share a position on screen, no caret to steer out of a marker, and no backspace
rule to keep `#Title` from appearing. Backspace at the start of a heading demotes it, because that
is the only thing the press can mean.

One trap worth recording. Per-line geometry cannot be asked for a line at a time: every
character-to-glyph route — `boundingRect(forGlyphRange:)`, `lineFragmentRect(forGlyphAt:)`, even
`caretRect(for:)` — aliases at paragraph boundaries, reporting the preceding blank line's position
for a line that follows one, and taking in the *following* fragment for a range that ends at a
newline. `EditorTextView` therefore walks the fragments once per draw and asks each which line
its first character belongs to, which is unambiguous and cheaper besides.

## Getting Started

The project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the `.xcodeproj`
from `project.yml`.

```sh
brew install xcodegen
xcodegen generate
open NeutrinoDocs.xcodeproj
```

Run the tests:

```sh
xcodebuild test -project NeutrinoDocs.xcodeproj -scheme NeutrinoDocs \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

The server defaults to `http://localhost:8080` and can be changed from the login screen's
**Server** field.

## Deploying to TestFlight

```sh
cp scripts/.env.example scripts/.env   # then fill in App Store Connect credentials
scripts/deploy_testflight.sh           # bump the build number by 1 and ship
scripts/deploy_testflight.sh 7         # ship build 7
scripts/deploy_testflight.sh 7 1.1.0   # build 7, marketing version 1.1.0
```

The script bumps `CURRENT_PROJECT_VERSION` in `project.yml` (the source of truth — `Info.plist`
reads it through `$(CURRENT_PROJECT_VERSION)`), regenerates the project with XcodeGen, runs the
unit tests, archives, exports an App Store `.ipa`, and uploads it with `xcrun altool`.
`--skip-tests` and `--no-upload` are available for iterating. Commit the `project.yml` bump
afterwards so the next build number starts from the right place.

Credentials come from `scripts/.env` (gitignored) — either an App Store Connect API key
(`ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_KEY_PATH`) or an Apple ID with an app-specific password
(`ASC_APPLE_ID` / `ASC_APP_PASSWORD`). See `scripts/.env.example`.

Signing is automatic and needs an *Apple Distribution* certificate for team `46KWJJ63FU`. Xcode 26
stores automatic-signing certificates in the data-protection keychain, where `security
find-identity` cannot see them, so the script verifies the exported `.ipa`'s embedded provisioning
profile and bundle version instead of preflighting the keychain — a development-signed or
stale-versioned build fails locally rather than being rejected by Apple ten minutes later.

## Architecture

The app is a six-tab SwiftUI shell — Home, Recent, Favorites, Shared, Offline, Settings — each with
its own `NavigationStack`. `NeutrinoDocsApp` is the composition root: every service is constructed
there and injected as an `EnvironmentObject`, with the graph's genuine cycles (the drive service
needs the offline store; the sync engine needs the drive service) wired explicitly through `weak`
references rather than hidden behind a container.

**Authentication** (`AuthService`) reuses Neutrino's three-step OAuth PKCE flow — a session login, an
in-app authorization step whose 302 carries the code, and a token exchange — with tokens in the
Keychain under `ndoc.*` keys, distinct from Drive's `nd.*` and Notes' `nn.*`. **Device registration**
turned out to have no endpoint of its own: the server (`src/auth/api.rs`) reads an `X-Device-Name`
header off the *login* request and writes it to the session row, so registration is a property of
signing in. `DeviceSessionService` reads that back through `GET /auth/sessions` and revokes with
`DELETE /auth/sessions/{id}`, which is what the Settings › Registered Devices screen shows.

**Encryption** is the same E2EE model as the web app and the sibling iOS apps, so a document written
on one is readable on the others: an XChaCha20-Poly1305 secretstream over the body, with the
per-file DEK sealed to the user's Curve25519 public key via `crypto_box_seal`. `KeyImportService`
validates an imported pair by deriving the public key from the private one (falling back to a
sign-and-verify for P-256) so a mismatched pair is rejected at import rather than silently failing to
decrypt later. The key can arrive as a file, as pasted JSON, or from the PIN-protected QR code the
web app displays — `KeyQRDecryptService` unwraps that envelope (PBKDF2-SHA256 over the PIN, then
XSalsa20-Poly1305 secretBox) and hands the plaintext to the same `KeyImportService` validation, so
the QR path has no separate trust in it. Keychain items are `AfterFirstUnlockThisDeviceOnly` — after first unlock so background
sync can still reach a token, this-device-only so neither the refresh token nor the private key ever
travels in an iCloud backup.

**Drive integration** (`DocsDriveService`) reuses Drive's existing folder/file/trash APIs and filters
every response to folders and Drive's document MIME type. Mutations are optimistic and roll back if
the server refuses. There is no whole-drive `type=` listing — `GET /api/v1/drive/folders/{id}?type=doc`
scopes to one folder (a user's root folder has no id of its own; it's addressed by the caller's own
user id, read from the access token's `sub` claim by `currentUserId()`), and Recent/Favorites use their
own dedicated `/api/v1/drive/recent` and `/api/v1/drive/starred` routes, both `type`-filterable. Shared
items arrive from an owner-scoped API, so a shared folder's `parentID` and the owner's `isStarred` flag
are both dropped — showing the latter would put a Favorites badge on somebody else's document that this
account never set and cannot clear.

**The document is the wire format.** A Neutrino Doc's body is the web editor's ProseMirror (TipTap)
JSON — the backend seeds a new file with `{"type":"doc","content":[]}`, and both apps read and write
the same file through the same Drive endpoints. The editor holds that same tree, so there is no
translation layer to lose anything: `NeutrinoDocumentCodec` is a thin envelope, entered just after
decrypting and left just before encrypting, and `DocumentProjection` / `DocumentBuilder` turn the
tree into styled text and back for as long as it is on screen.

The web app's `_meta` block (header, footer, page numbers, watermark, background, theme) is kept
verbatim as `DocumentBody.layout` and written back on every save, so editing a document on a phone
does not reset its page setup for everyone; it is threaded through the editing session, the offline
queue, and named versions for that reason. Front matter has no ProseMirror node of its own, so it is
written as a tagged leading `yaml` code block, which stays visible in the web app.

Nodes this app does not model — tracked changes, comments, embeds a newer web release adds — are
carried through untouched rather than dropped, so a phone can open and save a document without
quietly deleting what it cannot draw. A stored body that is not a ProseMirror document at all is
read as plain text, one paragraph per line: kept, and never guessed at.

**Duplicate** has no server-side endpoint at all — the filesystem API has no copy route — so it is a
client-side download-decrypt-re-encrypt-upload under a **fresh** DEK. Sharing a key between the
original and its copy would mean revoking access to one revoked access to both.

**The editor** (`DocEditorView`, `DocumentTextEditor`) is a `UITextView` rather than SwiftUI's
`TextEditor`, which offers no per-range attributes, no caret access, and no find interaction — three
of Phase 1's editor requirements. What the text view holds is a projection of the document, with
every character carrying its block and marks, so reading the document back is one linear walk of the
runs rather than a re-parse. Typing schedules a debounced save at the user's configured interval;
find & replace is UIKit's own find interaction. Smart quotes and dashes are *on*: there is no code
span or link syntax left for a curled quote to corrupt.

**Rendering** (`NeutrinoDocs/Rendering/`) is the projection and its inverse — `DocumentProjection`,
`DocumentBuilder`, `DocumentStyle` for how a block looks, `DocumentDecorations` for the bullets and
rules drawn beside the text, and `DocumentImageAttachment` for pictures, which are one atomic
character to the text system and so cannot come apart from the words around them.

**The outline** (`DocumentOutline`) is read off that projection: a heading is a heading because the
block says so, and the offsets are offsets into the very string the text view is showing, so
selecting a heading moves the caret exactly there.

**Offline and sync** (`OfflineStore`, `SyncEngine`) cache the server's ciphertext byte for byte and
re-encrypt local edits under the same DEK, so nothing is written to disk as plaintext and reading the
cache back still requires the Keychain key pair. The rule the whole feature rests on: **a queued edit
is uploaded only if the server is still on the version that edit was written against** — otherwise
the document is flagged as a conflict and left for the user, so a queued edit never silently clobbers
a remote one. Phase 1's queue covers body edits *and* metadata (`PendingMutation`: delete, move,
rename), with later mutations superseding earlier ones for the same item so "rename then delete" is
one round trip rather than two. Edits drain before mutations, so a document about to be trashed still
gets its last edit uploaded. `BackgroundSyncService` runs the same drain from a `BGProcessingTask`.

## Milestone 1 deliverable → test coverage

All 572 tests pass. Each M1 deliverable has dedicated coverage:

| Deliverable | Primary test file(s) | Tests |
|---|---|---|
| Login | `AuthServiceTests` (full PKCE flow, device header, refresh, logout, state mismatch) | 16 |
| Browse Drive | `DocsDriveServiceTests`, `DocItemTests`, `DocsSectionTests` | 46 |
| Open documents | `DocContentServiceTests`, `NeutrinoDocumentCodecTests`, `DocumentProjectionTests` | 70 |
| Edit | `EditorTests`, `DocumentProjectionTests`, `DocTextStatsTests` | 60 |
| Save | `DocContentServiceTests` (autosave, multipart framing, ciphertext round trip), `EditorTests` | in the above |
| Sync | `SyncEngineTests` (conflict detection, ordering, backoff, mutation replay), `SyncBackoffTests` | 28 |
| Work offline | `OfflineStoreTests`, `PendingMutationTests`, `CacheReasonTests` | 40 |
| Use Face ID | `BiometricAuthServiceTests` | 30 |

Supporting coverage: `KeychainServiceTests`, `KeyImportServiceTests`, `AppSettingsTests`,
`DeviceIdentityTests`, `DeviceSessionServiceTests`, `VersionHistoryServiceTests`, `DriveDateTests`,
`MultipartFormBodyTests`, `DocVersionTests`, `DocFileInfoTests`, `ShareRoleTests`.

## Milestone 2 deliverable → test coverage

Phase 2 adds 149 tests. The logic is deliberately factored into pure functions so the behaviour is
asserted directly rather than through a live text view:

| Deliverable | Primary test file(s) | Tests |
|---|---|---|
| Document round trip (blocks, marks, lists, tables, unknown nodes) | `DocumentProjectionTests` | 33 |
| Editing tools (toolbar commands, typing rules, folding, images) | `EditorTests`, `ImageAttributesTests` | 40 |
| Outline (navigation, collapse, search) | `DocumentOutlineTests` | 19 |
| Search extraction (title, headings, tags, previews) | `SearchIndexTests`, `SearchServiceTests` | 47 |

The interesting cases are the negative ones, and they are the ones worth reading: a `#` inside a
code block is not a heading, a code block is not indexed as prose, front matter is metadata rather
than body text, an attribute this app has never heard of survives a save, and a picture edited
through the properties panel rewrites nothing but itself.

Two deliberate choices about how these tests are written:

- **The crypto is never mocked.** A real X25519 pair goes into the Keychain and the real secretstream
  and `crypto_box_seal` primitives run, because a fake that always "decrypts" would assert nothing
  about the part of this app most expensive to get subtly wrong. Tests cover tampered ciphertext,
  wrong keys, and keys sealed to a different pair.
- **Networking is intercepted, not faked.** `MockURLProtocol` sits under a real `URLSession`, so the
  services are exercised through their actual request-building and decoding, including request-body
  capture — which is how "the uploaded body does not contain the plaintext" can be asserted at all.

`BiometricAuthServiceTests` includes a sweep asserting that *no* `LAError` unlocks the app, so a
newly handled error code cannot quietly become a bypass.

## Notable deviations from the sibling apps

- **No key material is logged.** The Notes app's content service logs DEKs, sealed DEKs, and
  ciphertext fingerprints at `error` level as debugging aids. That was not carried over: `os.log`
  messages persist in the system log store, and a key written there outlives the process that leaked
  it. `DocContentService` logs document IDs and byte counts and nothing else.
- **Services take an injected `URLSession`.** The siblings call `URLSession.shared` directly, which
  leaves their HTTP paths untestable. Every service here accepts a session (and `AuthService` a
  configuration, so its redirect-suppressing session is intercepted too).
- **Keychain accessibility is set explicitly** rather than left at the default.

## Known gaps and limitations

- **Starring requires a connection.** It is not in Phase 1's queue list ("pending saves, deletes,
  moves") and has no safe offline semantics, so an offline star is reverted with a message rather
  than silently dropped or wrongly queued.
- **Duplicate requires a connection**, since it reads the source's content to re-encrypt it.
- **Autosave does not create versions.** That is the server's design — only the initial upload and an
  explicit save snapshot — so history accumulates only via the editor's **Save Version…** action.
  This matches the web app.
- **Images with relative paths are not fetched.** A relative source points into Drive and needs an
  authorized request the viewer does not make; those render as alt text rather than spinning.
- **Background sync timing is not guaranteed.** iOS decides when a `BGProcessingTask` runs. It is an
  optimization on top of foreground sync, never what correctness depends on — every path that matters
  also drains on launch and on foreground.
- **Mid-paragraph images fall back to alt text**, since they cannot be drawn inside a SwiftUI `Text`.
  A paragraph that is entirely one image renders as a real image.
- **Multi-cursor is not implemented** — see the Phase 2 status section above. It is the one Phase 2
  item that is not done.
- **Inline math is Unicode, not laid out.** `$x^2$` becomes "x²" because a SwiftUI `Text` run cannot
  contain a view. A script with no Unicode form falls back to caret notation (`x^(abc)`). Display
  math (`$$…$$`) gets the real layout.
- **Only Mermaid flowcharts render.** Sequence, class, state, ER, Gantt, pie, and journey diagrams
  show their source in a card that names the type. Flowchart `RL` and `BT` directions are mapped
  onto `LR` and `TD` rather than drawn mirrored.
- **Front matter is a YAML subset**, not YAML: flat scalars, inline lists, and dash lists. Nested
  maps, anchors, and block scalars are shown as plain strings rather than interpreted.
- **Folding is display-only.** Folded text stays in the text storage, so saves and undo always see
  the full document — but folds reset when the editor is rebuilt, and are not persisted.
- **`DEVELOPMENT_TEAM` is inherited from the sibling apps** (`46KWJJ63FU`) and there is no TestFlight
  deploy script yet; the siblings' `scripts/deploy_testflight.sh` is the obvious thing to port when
  distribution is needed.
