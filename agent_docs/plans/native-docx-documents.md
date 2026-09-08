# Feature: a document is a `.docx`

Neutrino Docs reads and writes real Word documents. A document in Drive is
`application/vnd.openxmlformats-officedocument.wordprocessingml.document`, its Drive file is named
`Report.docx`, and Word, LibreOffice and Google's editors open one directly (issue #127).

Before this change the app read and wrote the bespoke `application/x-neutrino-doc` JSON, listed a
`.docx` without opening it, and showed *"This is a Word document (.docx) … open this one in Docs on
the web"* — which, since every document created by any client is now a `.docx`, meant every document.

**The bespoke JSON is gone from this app.** Not migrated — there is nothing to migrate — simply no
longer a format it reads, writes, lists or routes.

## Where the format lives

`NeutrinoOOXML`, a new module in `neutrino_shared_ios`. It depends on nothing else in that package:
a file format is not a client, and Sheets and Slides need the same zip and XML plumbing for `.xlsx`
and `.pptx`.

- `Zip/ZipArchive.swift` — the container. Stored and deflated entries via the Compression framework,
  no third-party dependency. Deterministic: entries keep insertion order and every header carries a
  fixed timestamp, because the offline cache decides whether a document changed by comparing what it
  encoded.
- `XML/XMLElement.swift` — a read-only DOM over `XMLParser`. `XMLDocument` does not exist on iOS, and
  a streaming parser cannot answer "this paragraph's properties, then its runs". Namespace
  processing is deliberately off: Foundation strips prefixes from attribute names with it on, and
  `w:id` and `r:id` sit on the same element meaning different things.
- `Docx/DocxMapping.swift` — the correspondence between the document model and OOXML, in one place
  so the reader and the writer cannot drift apart silently.
- `Docx/DocxWriter*.swift`, `Docx/DocxReader*.swift` — the two halves of that mapping.
- `Docx/DocxCodec.swift` — the public door. Callers speak the stored `{ doc, _meta }` envelope, so
  this app keeps its own `ProseMirrorNode` types and converts once rather than twice.

This is the Swift half of `web/apps/web/src/lib/ooxml/docx/{mapping,read,write}.ts`. **The two are
one wire format** — a document written on a phone is opened on the web and the other way round — so
a change to either belongs in both, and both repositories assert `read(write(m)) == m` over a
document carrying one of everything.

## What OOXML cannot hold

Four things in the model have no OOXML equivalent, and they are all the same shape — a live pointer
at another Drive file, which no interchange format models: `neutrino-drive:` image references, sheet
embeds, diagram embeds, and the `docTheme` preset name. A few presentational attributes (image
shadow, filter, caption; a cross-reference's target text; `showCode` on a field) have no home either.

Those go in `customXml/item1.xml`, addressed by each node's index in document order. Word keeps
`customXml/` parts across an edit and discards parts it does not recognise, so a document that has
been through Word comes back with its extras intact. A document *edited* in Word comes back with the
indices no longer lining up, and then the extras for anything after the edit are dropped and the base
content — which is all real OOXML — still reads. Full fidelity is a Neutrino-to-Neutrino property; it
cannot be anything else once another editor has had the file.

## Pictures

A picture in a document is a reference to another Drive file, encrypted to its own key, and a `.docx`
has to carry the bytes. Only the client holding the key can fetch them, so writing is two steps:
`DocumentBody.imageSources` says what the document needs, `DocContentService.imageBytes(for:)`
resolves what it can (memoised, and warmed by the same fetch the editor uses to draw a picture), and
the codec embeds what it was given.

What it could not resolve — a save made with no connection — is written as a *placeholder run*
carrying the whole image node in the extras. The picture is still in the document when it is read
back, and the upload that follows re-encodes it with the bytes in hand: `SyncEngine` hands the
uploaded package to `OfflineStore.clearPendingEdit(uploaded:dek:)` so the cache records what the
server actually holds rather than the placeholder version it queued.

## What changed in the app

- `DocItem` — one MIME type. `displayName` strips `.docx`; `duplicateName` puts it back on the end,
  because `Report.docx copy` is a file the operating system no longer recognises.
- `NeutrinoDocumentCodec` — the seam. `Data` in, `Data` out; takes the document's title (a
  `{{title}}` field resolves to it) and whatever pictures the caller resolved. A body that is not a
  package still opens as plain text, so nothing is ever unreadable.
- `DocContentService` — creates a real, empty `.docx` rather than an empty blob, so a new document
  downloads and opens in Word before it has ever been edited. `SaveResult` now carries the bytes that
  were uploaded, so no caller re-encodes the same body and risks producing something subtly different.
- `DocsDriveService` — names new files `Title.docx`, re-applies the extension on rename (the sheet
  shows the title), and `fetchItem` judges a file by `DocItem.isDocument` rather than by the shared
  link vocabulary, which is deliberately more forgiving about formats this app no longer reads.
- `OfflineStore`, `VersionHistoryService`, `SyncEngine`, `SearchService` — all move package bytes
  rather than text. A `.docx` is now indexed like any other document instead of being skipped.

## Known limits, shared with the web writer

- An image's `alignment` and `border` are dropped once its bytes are embedded: a `.docx` frames and
  positions a picture in ways the editor's CSS does not map onto. An unresolved picture keeps every
  attribute, since it travels as a placeholder.
- A code block's newlines go into the package verbatim; Word draws each as a space. Writing `w:br`
  instead would look right in Word and lose the text the moment another Neutrino client read it back.
- `styles.xml` is not resolved: a heading is a heading because its style is spelled `Heading2`. A
  document whose heading styles are named in another language reads as body paragraphs with its text
  intact. The web reader has the same gap, deliberately, so the two stay in step.

## Also in this change

`BGTaskScheduler` handlers were registered from a view's `.task`, which iOS treats as fatal — *"All
launch handlers must be registered before application finishes launching"* — so the app crashed on
launch under the test host and the whole suite could not run. Registration moved to
`NeutrinoDocsApp.init()`; scheduling still happens once the graph is wired.
