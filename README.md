# Neutrino Docs iOS

A secure, offline-capable document editor for the Neutrino ecosystem. Built with SwiftUI,
the app reuses Neutrino Drive as its storage layer and the existing Neutrino Auth and E2EE key
services rather than inventing its own.

## Tech Stack

- Swift / SwiftUI, iOS 16+
- Xcode / XcodeGen
- [swift-sodium](https://github.com/jedisct1/swift-sodium) — XChaCha20-Poly1305, `crypto_box_seal`

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
things the editor needs. What the text view holds is a projection of the document, with
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
a remote one. The queue covers body edits *and* metadata (`PendingMutation`: delete, move,
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

The editing and search work adds 149 tests. The logic is deliberately factored into pure functions so the behaviour is
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

- **Starring requires a connection.** The offline queue holds saves, deletes, moves and renames
  only, and a star has no safe offline semantics, so an offline star is reverted with a message rather
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
- **Multi-cursor is not implemented.** `UITextView` supports exactly one insertion point, and
  neither TextKit 1 nor TextKit 2 exposes a way to add another.
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
