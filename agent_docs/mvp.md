Neutrino Docs for iOS – Feature Roadmap

This roadmap assumes the iOS app is a native SwiftUI application that shares the same backend APIs, authentication, encryption model, and document format as the Neutrino web application. Like the existing Neutrino Drive iOS roadmap, development is phased so the application is usable early while steadily approaching feature parity with the web version.

⸻

Goals

* Native iOS experience
* Offline-first editing
* End-to-end encrypted documents
* Shared document model with web
* Fast startup and synchronization
* Excellent Markdown editing experience
* Works seamlessly with Neutrino Drive

⸻

Architecture

Platform

* SwiftUI
* Swift Concurrency
* Observation framework
* Combine where appropriate
* URLSession
* Core Data or SwiftData for local cache
* BackgroundTasks framework
* QuickLook
* PencilKit (future)
* TextKit 2

⸻

Shared Services

* Authentication
* Keychain integration
* Encryption services
* Document synchronization
* Presence/session APIs
* Version history APIs
* Search APIs
* Sharing APIs

⸻

Phase 1 — MVP

Goal

Users can securely open, edit, and save markdown documents from Neutrino Drive.

⸻

Authentication

* Login
* Refresh tokens
* Logout
* Device registration

⸻

Encryption

Use the same E2E encryption model as web.

Features

* Import user key
* Store in Keychain
* Unlock using Face ID
* Unlock using Touch ID
* Automatic key loading
* Secure memory handling

⸻

Drive Integration

Browse Drive

* Home
* Recent
* Favorites
* Shared
* Folder navigation

Operations

* Open file
* Create document
* Rename
* Delete
* Move
* Duplicate

⸻

Document Viewer

Markdown rendering

Support

* Headings
* Lists
* Tables
* Blockquotes
* Code blocks
* Images
* Links
* Checklists

⸻

Markdown Editor

Editing

* Plain text editing
* Syntax highlighting
* Live preview toggle
* Auto-save
* Undo
* Redo
* Find
* Replace

⸻

Synchronization

* Manual sync
* Auto-sync
* Conflict detection
* Background upload
* Background download

⸻

Offline Mode

Cache

* Open documents
* Recently viewed
* Favorites

Queue

* Pending saves
* Pending deletes
* Pending moves

⸻

Version History

View

* Previous versions
* Restore version
* View timestamps

⸻

Settings

* Theme
* Font size
* Editor font
* Auto-save interval
* Sync settings

⸻

Milestone 1 Deliverable

Users can:

* Login
* Browse Drive
* Open markdown documents
* Edit
* Save
* Sync
* Work offline
* Use Face ID

⸻

Phase 2 — Better Editing

Goal

Provide an editor comparable to Obsidian and Bear.

⸻

Rich Markdown

Support

* Tables
* Footnotes
* Task lists
* Mermaid
* Math
* Callouts
* Front matter

⸻

Editor Improvements

* Multi-cursor
* Smart indentation
* Auto bullets
* Auto numbering
* Auto closing brackets
* Keyboard shortcuts
* Line numbers
* Code folding

⸻

Formatting Toolbar

Quick buttons

* Bold
* Italic
* Link
* Image
* Code
* Quote
* Table
* Checkbox

⸻

Document Outline

Automatically generated

* Heading navigation
* Collapse sections
* Search headings

⸻

Split View

iPad

* Editor
* Preview

⸻

Phase 3 — Attachments

⸻

Images

Insert

* Camera
* Photo library
* Files

Editing

* Resize
* Crop
* Rotate

⸻

File Attachments

Support

* PDFs
* ZIP
* Office files
* Audio
* Video

⸻

Drag and Drop

iPad

* Files app
* Photos
* Safari

⸻

Clipboard

Paste

* Images
* Rich text
* URLs

⸻

Phase 4 — Collaboration

⸻

Sharing

Invite

* Read
* Comment
* Edit

⸻

Comments

* Inline comments
* Threads
* Resolve
* Mentions

⸻

Presence

Show

* Active users
* Cursor positions
* Current editor

⸻

Conflict Resolution

Visual merge

* Mine
* Theirs
* Merge

⸻

Phase 5 — Search

⸻

Local Search

Indexed

* Titles
* Content
* Headings
* Tags

⸻

Global Search

Across Drive

Filters

* Owner
* Folder
* Modified
* Tags

⸻

Saved Searches

⸻

Phase 6 — Advanced Document Features

⸻

Templates

Create from

* Blank
* Meeting Notes
* Journal
* Project Plan
* Daily Notes
* Knowledge Base

⸻

Document Metadata

Display

* Author
* Created
* Modified
* Word count
* Reading time

⸻

Tags

* Inline tags
* Filter
* Browse

⸻

Backlinks

* Incoming links
* Outgoing links

⸻

Wiki Links

[[Page]]

⸻

Embedded Documents

![[Another Page]]

⸻

Phase 7 — iPad Productivity

⸻

Stage Manager

Support multiple windows.

⸻

Multi-window Editing

Open multiple documents simultaneously.

⸻

Keyboard Support

Shortcuts for

* Search
* Save
* Undo
* Redo
* Navigation
* Formatting

⸻

External Display

Optimized layouts.

⸻

Apple Pencil

* Handwriting
* Scribble
* Drawing blocks

⸻

Phase 8 — AI Features

⸻

Writing Assistant

* Grammar
* Rewrite
* Expand
* Summarize

⸻

Smart Search

Natural language

Example

“Show meeting notes from last month.”

⸻

Document Chat

Ask questions about the current document.

⸻

Automatic Tags

⸻

Suggested Links

⸻

Document Summaries

⸻

Phase 9 — Publishing

⸻

Export

* Markdown
* PDF
* HTML
* DOCX
* Plain Text

⸻

Printing

Native AirPrint support.

⸻

Share Sheet

Share as

* File
* PDF
* Link

⸻

Public Links

Generate secure read-only links.

⸻

Phase 10 — Full Web Parity

Complete support for every feature available in the Neutrino Docs web application.

Examples include:

* Advanced permissions
* Full revision browser
* Enterprise policy enforcement
* Shared Team Spaces integration
* Document workflows
* Approval states
* Custom metadata
* Automation hooks
* Embedded Sheets and Slides
* Cross-application linking
* Live collaborative editing
* Plugin architecture

⸻

Cross-Cutting Features (Implemented Throughout)

Performance

* Incremental document loading
* Lazy rendering
* Background parsing
* Memory-efficient editing for large documents
* Fast startup (<2 seconds)

⸻

Security

* End-to-end encryption
* Secure Enclave / Keychain storage
* Face ID / Touch ID unlock
* Certificate pinning
* Secure clipboard handling
* Automatic lock after inactivity

⸻

Accessibility

* VoiceOver
* Dynamic Type
* High contrast
* Keyboard navigation
* Switch Control
* Reduced motion

⸻

Quality

* Crash reporting
* Analytics (privacy-preserving)
* Unit tests
* Snapshot UI tests
* Integration tests
* Offline synchronization tests

⸻

Recommended Milestones

Milestone	Deliverable
M1	Authentication, key management, Drive integration, open/edit/save Markdown documents
M2	Full-featured Markdown editor, live preview, outline, rich editing tools
M3	Attachments, image support, drag-and-drop, clipboard integration
M4	Sharing, comments, presence, conflict resolution
M5	Offline search, global search, saved searches
M6	Templates, tags, backlinks, wiki links, embedded documents
M7	iPad productivity, multi-window support, keyboard shortcuts, Apple Pencil
M8	AI writing assistance, document chat, smart search, automatic tagging
M9	Export, publishing, AirPrint, public sharing
M10	Complete feature parity with the Neutrino Docs web application, including Shared Team Spaces and enterprise collaboration features

This phased approach mirrors the evolution of mature document editors while leveraging the existing Neutrino backend and encryption infrastructure, ensuring the iOS app can reach production quickly with a strong MVP and progressively add advanced collaboration and knowledge-management capabilities.