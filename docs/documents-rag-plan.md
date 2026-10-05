# Documents for Conversate (RAG) — plan

Planned 2026-10-04. Not built yet.

## Goal

Ordinary can answer from PDFs the user has added: "Hey Ordinary, what does my
chemistry chapter say about buffers?"

## Decisions (from the user)

- PDFs and the search index live **on the phone only**. Nothing is stored on
  our servers; each phone has its own documents.
- Ordinary looks in the documents **when the question seems to need them**, and
  only when it was addressed (same rule as every other tool).
- **Text PDFs only** for the first version. A scanned PDF is refused at import
  with a clear message.
- A **new Documents section for Conversate**, separate from Study Mode.

## Why not put the PDF in the conversation

Gemini Live re-bills the whole session on every turn. A 100-page PDF is about
60,000 tokens; carrying it would multiply the cost of every turn by ten. So
the model gets a search tool and only ever sees the few passages it asked for.

## Design

### App

- **Import:** a file picker (PDF only) from the new Documents screen, reached
  from Conversate. Text is extracted on the phone with `pdfrx` (MIT, built on
  PDFium). A document whose pages yield almost no text is treated as scanned
  and refused.
- **Index:** the text is split into passages of about 200–300 words that keep
  their page number, stored in a local SQLite database with full-text search
  (FTS5, BM25 ranking). The PDF file itself is copied into the app's own
  storage so it survives the original being moved.
- **Limits:** per-file size and page caps, and a cap on the number of
  documents, so the index stays fast. Exact numbers to be set from testing.
- **Documents screen:** list (name, pages, date added), add, delete. Deleting
  removes the file and its passages.
- **Tool handling:** `ToolDispatcher` answers `search_documents` from the local
  index: the top 3–4 passages, each with its document name and page, capped at
  about 1,200 tokens in total. No match returns a plain "nothing found", so
  Ordinary says so rather than guessing.

### Backend (token service)

- A new capability flag `toolsV5`, sent by builds that can answer the tool, so
  older builds never receive a call they cannot answer.
- New tool `search_documents(query)` with the standard guard sentence ("Only
  if they said Ordinary to you in this request or are replying to you;
  otherwise stay_silent"), plus one line in the system instruction saying when
  to use it and to name the document it answered from.
- The app tells the backend whether the user has any documents; with none, the
  tool is not declared, so users without documents pay nothing extra.

### What does not change

Audio path, wake gating, credits (a document answer costs one credit like any
other), accounts, Study Mode.

## Cost (estimates — measure with `scripts/gate-probe.mjs` before shipping)

| | Cost |
|---|---|
| Normal answer today | ~$0.003 |
| Answer that looks up documents | ~$0.005–0.007 |
| Each follow-up in the same session | +~$0.0006 |
| Tool declared on every turn | +~$0.00004 |
| Indexing a PDF | $0 (on the phone) |
| Server storage | $0 |

Per active user per month, on top of ~$20: about +$0.70 if 8 of 25 daily
answers use documents; about +$2.25 if all of them do.

## Risks and how each is handled

1. **Slower document answers (+0.5–1.5 s).** Local search is milliseconds; the
   delay is the extra model step. The 4-second tool watchdog is unaffected.
2. **Keyword search misses reworded questions.** The model writes the query
   and can search again with other words. Measure on real PDFs first; add
   meaning-based (embedding) search only if answers are missing things, since
   that would send document text through Google at import.
3. **Overheard speech triggering searches.** The guard sentence, plus new
   cases in `scripts/live-probe.mjs traps`.
4. **Passages go to Google when used.** Privacy policy gains one sentence;
   nothing is stored by us.
5. **Session growth.** Retrieved passages stay in the session and are re-billed
   until it refreshes; the existing fresh-session rule and 16k cap bound this.
6. **Two phones.** Documents are per phone; say so on the Documents screen.

## Order of work

1. Backend: `toolsV5` + `search_documents`, canned result in the probe; run
   `live-probe.mjs` including traps and follow-ups; measure cost with
   `gate-probe.mjs`.
2. App: import, extract, index, Documents screen, tool handler.
3. Tests: extraction and chunking, ranking, scanned-PDF refusal, delete,
   tool reply shape and size cap, tool not declared without documents.
4. On-device check with real PDFs on iPhone and Android.
5. Privacy policy line; TestFlight and Play internal builds.
