# Feature: Opening a document from a Universal Link

Neutrino Drive hands a document to this app with:

```
https://www.getneutrino.app/open/doc/<file id>[?v=<content version>]
```

The same link opens the document in the web app when Docs is not installed, which is the whole
reason this is an `https` link rather than a `neutrinodocs://` scheme.

**Only the file id travels.** The document itself is fetched here, against this app's own session,
so the reader always sees the current version and permissions stay server-side. `v` is an advisory
hint and nothing branches on it.

## Pieces

- `Models/NeutrinoAppLink.swift` — the link vocabulary and the MIME → app routing table.
  **Duplicated verbatim** in `neutrino_drive_ios_mobile` and `neutrino_notes_ios_mobile`: it is a
  wire format between three separately shipped binaries, so an app built last month must still open
  a link minted today. `NeutrinoAppLinkTests` pins it in each repository.
- `Services/DeepLinkRouter.swift` — holds the destination until there is a session to open it with.
  Accepts `/open/doc/*` only; a `/open/note/…` link belongs to Neutrino Notes.
- `DocsDriveService.fetchItem(id:)` — `GET /api/v1/drive/files/{id}/metadata`. `item(id:)` only sees
  listings this session loaded, and a link routinely names a document in a folder nobody has opened,
  or one shared by another account. Throws `.notFound` for a file that is not a Neutrino document:
  an `/open/doc/…` link pointing at a spreadsheet is malformed, and rendering the bytes as Markdown
  would show garbage instead of an error. Covered by `DocsDriveServiceDeepLinkTests`.
- `ContentView.openPendingLink()` — switches to Home and pushes the editor. Home's `NavigationPath`
  moved up from `DocBrowserView` to `ContentView` so a link can push onto it from outside the
  browser; the browser's own rows still push their destination view directly, and only the deep link
  pushes by value.

## Why nothing clears `pending` but `consume()`

A link can arrive at a cold launch straight onto the login screen, or while the biometric lock
overlay is up. The router remembers the destination and the view layer picks it up once the user is
signed in, so a link that arrives before sign-in survives the whole login round trip.

## Deployment

Nothing works until `apple-app-site-association` is served from `www.getneutrino.app` listing
`46KWJJ63FU.com.neutrino.docs` against `/open/doc/*`. That document, and the manual verification
steps for the whole feature, live in `neutrino_drive_ios_mobile`:

- `deploy/apple-app-site-association`, `deploy/README.md`
- `agent_docs/plans/feature-universal-links.md`
- `agent_docs/plans/feature-universal-links-verification.md`

## Kill switch

`FeatureFlags.appLinks`. It stops the app acting on links, but does not remove the `applinks:`
entitlement — that is a bundle property, so iOS still launches the app with the URL and `onOpenURL`
drops it.
