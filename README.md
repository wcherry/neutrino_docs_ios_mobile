# Neutrino Docs iOS

A secure, offline-capable Markdown document editor for the Neutrino ecosystem. Built with SwiftUI,
the app reuses Neutrino Drive as its storage layer and the existing Neutrino Auth and E2EE key
services rather than inventing its own.

## Tech Stack

- Swift / SwiftUI, iOS 16+
- Xcode / XcodeGen
- [swift-sodium](https://github.com/jedisct1/swift-sodium) — XChaCha20-Poly1305, `crypto_box_seal`
- [swift-markdown](https://github.com/swiftlang/swift-markdown) — CommonMark + GFM

## Phase 1 (MVP) Status

Every Phase 1 feature in [agent_docs/mvp.md](agent_docs/mvp.md) is implemented.

| Area | Features | Status |
|------|----------|--------|
| Authentication | Login, refresh tokens, logout, device registration | COMPLETE |
| Encryption | Import key (file, paste, or QR scan), Keychain storage, Face ID / Touch ID unlock, automatic key loading | COMPLETE |
| Drive Integration | Home, Recent, Favorites, Shared, folder navigation; open, create, rename, delete, move, duplicate | COMPLETE |
| Document Viewer | Headings, lists, tables, blockquotes, code blocks, images, links, checklists | COMPLETE |
| Markdown Editor | Plain text, syntax highlighting, live preview toggle, auto-save, undo, redo, find, replace | COMPLETE |
| Synchronization | Manual sync, auto-sync, conflict detection, background upload/download | COMPLETE |
| Offline Mode | Cache open/recent/favorite documents; queue pending saves, deletes, moves | COMPLETE |
| Version History | Previous versions, restore, timestamps | COMPLETE |
| Settings | Theme, font size, editor font, auto-save interval, sync settings | COMPLETE |

## Phase 2 (Better Editing) Status

| Area | Features | Status |
|------|----------|--------|
| Rich Markdown | Tables, footnotes, task lists (Phase 1); callouts, front matter, Mermaid, math | COMPLETE |
| Editor Improvements | Smart indentation, auto bullets, auto numbering, auto closing brackets, keyboard shortcuts, line numbers, code folding | COMPLETE except multi-cursor |
| Formatting Toolbar | Bold, italic, link, image, code, quote, table, checkbox (plus strikethrough and lists) | COMPLETE |
| Document Outline | Heading navigation, collapse sections, search headings | COMPLETE |
| Split View | Editor and preview side by side on iPad | COMPLETE |

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

### Rich Markdown notes

Mermaid and math are rendered **natively**, not through a bundled JavaScript engine:

- **Mermaid** — `MermaidParser` reads the flowchart family (`graph` / `flowchart`) and
  `MermaidLayout` places nodes with a layered, deterministic layout. Other diagram types (sequence,
  class, Gantt, ER, pie) parse to `nil` and fall back to a labelled source card that names the type,
  rather than failing silently.
- **Math** — `MathParser` covers the TeX subset documents actually use: `^`/`_` scripts, `\frac`,
  `\sqrt` with an optional index, `\left`/`\right`, `\text`, and tables of Greek letters, operators,
  and functions. Display math (`$$…$$`, ```` ```math ````) gets real two-dimensional layout in
  `MathView`. Inline math (`$…$`) is flattened to Unicode by `MathTextRenderer`, because a SwiftUI
  `Text` run cannot host a view. Unknown commands are preserved as source instead of dropped.
- **Callouts** — `> [!NOTE]`, `tip`, `important`, `warning`, `caution`, with an optional custom
  title. An unrecognised keyword stays an ordinary block quote.
- **Front matter** — a leading `---` block is read as flat key/value pairs (scalars, inline lists,
  dash lists) and shown as a collapsed metadata card. This is deliberately a small YAML subset, not
  a YAML engine.

### Editing notes

The formatting commands and typing behaviours are pure functions over an `EditorTextState` (text
plus selection), which is what makes them testable without a live text view. Code folding suppresses
glyphs and zeroes line fragments through an `NSLayoutManagerDelegate`, leaving the text storage
untouched — so the binding, autosave, and undo always see the full source and editing a folded
document cannot corrupt it. That is also why the editor builds a TextKit 1 stack explicitly: the
gutter needs per-fragment geometry that TextKit 2 does not expose.

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
every response to folders and Drive's Markdown MIME type. Mutations are optimistic and roll back if
the server refuses. Two server behaviours shape the code: `view=recent`/`view=starred` cannot be
combined with `type=note` (the handler checks `type` first and returns before it looks at `view`), so
those listings are filtered client-side; and shared items arrive from an owner-scoped API, so a
shared folder's `parentID` and the owner's `isStarred` flag are both dropped — showing the latter
would put a Favorites badge on somebody else's document that this account never set and cannot clear.

**The stored document format is not Markdown.** A Neutrino Doc's body is the web editor's
ProseMirror (TipTap) JSON — the backend seeds a new file with `{"type":"doc","content":[]}`, and both
apps read and write the same file through the same Drive endpoints. Markdown is this app's editing
surface, not its wire format. `NeutrinoDocumentCodec` is the single point where that translation
happens: once just after decrypting, once just before encrypting, with `ProseMirrorMarkdownReader`
and `ProseMirrorMarkdownWriter` doing the work either way. Everything above the codec — the editor,
the parser, the viewer, the offline cache's plaintext accessors — still speaks Markdown.

Two things travel alongside the text because Markdown cannot hold them. The web app's `_meta` block
(header, footer, page numbers, watermark, background, theme) is kept verbatim as `DocumentBody.layout`
and written back on every save, so editing a document on a phone does not reset its page setup for
everyone; it is threaded through the editing session, the offline queue, and named versions for that
reason. Front matter goes the other way — it has no ProseMirror node, so it is written as a tagged
leading `yaml` code block, which reads back as a `---` fence here and stays visible in the web app.

The translation is lossy in one direction, and deliberately so: font sizes, colours, text alignment,
tracked changes and comments have no Markdown spelling and do not survive a save made from this app.
Bodies written by earlier builds of this app were raw Markdown; they still open, and are migrated to
the shared format the first time they are saved.

**Duplicate** has no server-side endpoint at all — the filesystem API has no copy route — so it is a
client-side download-decrypt-re-encrypt-upload under a **fresh** DEK. Sharing a key between the
original and its copy would mean revoking access to one revoked access to both.

**The editor** (`DocEditorView`, `MarkdownTextEditor`) is a `UITextView` rather than SwiftUI's
`TextEditor`, which offers no per-range attributes (so no syntax highlighting), no caret access, and
no find interaction — three of Phase 1's editor requirements. Syntax highlighting is a separate
tokenizer (`MarkdownSyntaxHighlighter`) rather than the AST parser: the editor still shows every `#`
and backtick and only wants them styled, whereas the parser throws the syntax away. Typing schedules
a debounced save at the user's configured interval; find & replace is UIKit's own find interaction.
Smart quotes and dashes are disabled, since Markdown is source text and curling a quote inside a code
span corrupts it.

**Rendering** (`NeutrinoDocs/Rendering/`) sits on swift-markdown for CommonMark + GFM, with a
hand-rolled pass for footnotes, which are not part of GFM: definitions are lifted out, references are
rewritten into links under an internal `ndoc-footnote://` scheme so cmark parses them as ordinary
nodes, and the numbering follows first appearance rather than definition order.

Phase 2 adds three more passes around cmark, each for the same reason — the syntax is not
CommonMark or GFM, and cmark would otherwise leave it as inert text. Front matter is split off
*before* parsing, since a leading `---` would read as a thematic break. Display math is folded into
a ```` ```math ```` fence before parsing, so a multi-line `$$…$$` survives as one block rather than
a paragraph of soft breaks. Inline `$…$` is extracted *after* parsing, per text run, so math inside
emphasis or a table cell is found while math inside a code span is not — cmark has already claimed
those. The inline-math pattern requires its delimiters to hug non-space characters, which is what
stops "it cost $5 and $10" becoming an equation.

**The outline** (`DocumentOutline`) is built from Markdown *source*, not from the parsed document
model, for two reasons: it has to work in Edit mode where there is no rendered document to walk, and
it needs each heading's character offset so selecting one can move the editor's caret there.

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

All 487 tests pass. Each M1 deliverable has dedicated coverage:

| Deliverable | Primary test file(s) | Tests |
|---|---|---|
| Login | `AuthServiceTests` (full PKCE flow, device header, refresh, logout, state mismatch) | 16 |
| Browse Drive | `DocsDriveServiceTests`, `DocItemTests`, `DocsSectionTests` | 46 |
| Open markdown documents | `DocContentServiceTests`, `MarkdownParserTests`, `MarkdownInlineRendererTests` | 70 |
| Edit | `MarkdownSyntaxHighlighterTests`, `EditorTests`, `DocTextStatsTests` | 60 |
| Save | `DocContentServiceTests` (autosave, multipart framing, ciphertext round trip), `EditorTests` | in the above |
| Sync | `SyncEngineTests` (conflict detection, ordering, backoff, mutation replay), `SyncBackoffTests` | 28 |
| Work offline | `OfflineStoreTests`, `PendingMutationTests`, `CacheReasonTests` | 40 |
| Use Face ID | `BiometricAuthServiceTests` | 30 |

Supporting coverage: `KeychainServiceTests`, `KeyImportServiceTests`, `AppSettingsTests`,
`DeviceIdentityTests`, `DeviceSessionServiceTests`, `VersionHistoryServiceTests`, `DriveDateTests`,
`MultipartFormBodyTests`, `DocVersionTests`, `DocFileInfoTests`, `ShareRoleTests`.

## Milestone 2 deliverable → test coverage

Phase 2 adds 112 tests. The logic is deliberately factored into pure functions so the behaviour is
asserted directly rather than through a live text view:

| Deliverable | Primary test file(s) | Tests |
|---|---|---|
| Rich Markdown (callouts, front matter, math, Mermaid) | `RichMarkdownTests` | 42 |
| Rich editing tools (toolbar commands, smart typing, folding) | `EditorCommandTests` | 51 |
| Outline (navigation, collapse, search) | `DocumentOutlineTests` | 19 |

The interesting cases are the negative ones, and they are the ones worth reading: currency amounts
are not math, `$` inside a code fence is not math, an unknown `[!KEYWORD]` stays a block quote, a
`#` comment inside a code fence is not a heading, front matter's closing `---` is not a Setext
underline, an arrow inside a Mermaid node label is not an edge, and a cyclic Mermaid graph still
terminates.

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
