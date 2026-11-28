# notchban

A kanban board that lives in your Mac's notch, for people who run coding agents.
It shows every `KANBAN.md` in your projects folder and who is working on what: Claude Code and Codex
sessions, their subagents, their 5-hour and weekly limits. It writes a board only when you act on it yourself.

**[Download the latest release](https://github.com/opsida-technology/notchban/releases/latest)**: unzip, move
`Notchban.app` to Applications, open it. macOS 13 or later, Apple silicon.

![The board hanging from the notch](docs/images/board.png)

## The notch

![The pill over the notch: Codex's limits on the left, Claude's on the right](docs/images/notch.png)

A pill over the notch with an ear on each side: Codex on the left, Claude on the right. Each ear shows the
5-hour and weekly limits as two rings, the 5-hour figure with when it resets, and how many agents work now.
Put the pointer on the pill (or click it, or ⌥⌘B) and the whole board hangs from the notch; Esc, a click
elsewhere or the pointer leaving closes it. Figures more than half an hour old are dimmed. The board switcher's menu can also send a notification when a card newly needs you.

## The board

- Seven columns of cards: id, title, owner avatar, size and risk chips, checklist ring, track
  colour, lease countdown, a pulsing red alarm on a stale lease, the blocker line, "waits for N"
  and "unlocks N". Empty columns collapse on their own; click a header to collapse any.
- Lanes by Status, Track or Phase.
- Select a card: what it waits for lights sky blue, what it unlocks indigo, with curves between them;
  "Show only this chain" hides the rest. "Critical path" shows the heaviest open chain, by size.
- Filters: search, owner, track, risk, and "Ready & unblocked" (Ready, no open predecessor, gate open).
- The side sheet: facts, owner and lease, blocker, Proof, dependencies, checklist and notes.
- The agents screen (A, or the toolbar's agents toggle): who works where. Every live Claude Code and Codex session
  is a node with its folder, branch and the cards it names; Claude's subagents branch off below it, with their
  model. The ears' badge counts the same working agents and subagents.
- Reloads the moment a `KANBAN.md` changes (FSEvents); a full rescan each minute finds new boards.
- Always dark, VoiceOver labels; animations respect Reduce Motion.

![A card's sheet: what it waits for and unlocks, the owner's lease, the checklist](docs/images/card.png)

![The critical path](docs/images/critical-path.png)

![The agents screen: every live Codex and Claude Code session, with its subagents](docs/images/agents.png)

The screenshots show made-up boards and sessions.

| Key | Does |
|---|---|
| j k h l, arrows | move between cards |
| Return, Space | open or close the card's sheet |
| / | search |
| ⌘K | palette: any card on any board, boards, view commands |
| g | cycle lanes: Status, Track, Phase |
| a | the agents screen |
| c | critical path |
| f | only the selected card's chain |
| r | only ready and unblocked |
| [ ] | previous / next board |
| n | next card waiting in Human Review, on any board |
| 1 2 3 4 | on a Human Review card: Done, Approve, Changes, Hold |
| ⌘Z | undo your last verdict |
| Esc | back out one layer |
| ⌘Q | quit (also in the board switcher's menu) |

## A board

A board is a `KANBAN.md` at a repository's root whose first line is `# Kanban`. The `##` section a card sits in
is its status:

```markdown
# Kanban
<!-- squawk-kanban:v1 -->

## Backlog

## Ready

### KB-12 — Short imperative title
<!-- squawk:{"owner":"agent:task-x","after":["KB-09"],"size":"M"} -->

- [ ] Acceptance item one
- [ ] Acceptance item two

## In Progress

## Human Review

## Verified

## Blocked

## Done
```

The metadata line is optional JSON: `owner`, `task`, `lease`, `after`/`before` (predecessor and successor ids),
`track`, `phase`, `size`, `risk`, `tier` and `gate`. `Proof:` and `Blocker:` lines are shown on their own.
The full format, written as a Claude Code skill, is in [docs/kanban-skill.md](docs/kanban-skill.md); the app
offers to install it the first time the board opens, so your agents keep the board current.

## On your iPhone

A companion app for iPhone (iOS 17 or later) shows the same boards when you are away from the desk and lets you
act on them: approve a card in Human Review or send it back with a note, add a card, leave a note, set a due date.
It also shows what the notch's ears show: Codex and Claude agents at work and their 5-hour and weekly limits.
Your Mac stays the only place the boards live; the phone keeps the last copy it saw and sends your changes to the
Mac, which writes them into the `KANBAN.md` like any other edit of yours.

- **Pairing**: on the Mac, the board switcher's menu › Pair iPhone… shows a QR code; scan it with the app. The code
  works once, for two minutes. It carries a fresh secret from the Mac's screen to the phone's camera, so the secret
  never goes over the air. "Forget This iPhone" in the same window undoes it.
- **The link**: Wi-Fi or Bluetooth, straight between the two (MultipeerConnectivity). No account, no server, no
  cloud. Each session agrees new keys, both sides prove the paired secret over them, and every message after that
  is sealed (ChaChaPoly), so nobody nearby can read, change or replay it.
- **Away from home, over Tailscale** (optional): with Tailscale on both, turn on board menu › Reach the iPhone over
  Tailscale. The Mac then listens on its Tailscale address only (TCP 47621) and takes paired phones only, with the
  same proofs and seal; the phone uses it whenever the Mac is not nearby. Pairing still needs the QR code.
- **Verdicts**: swipe the card (right approves, left asks for changes, up is done, down holds). A verdict waits
  five seconds with an Undo bar before it is sent.
- **Projects and boards**: on the home screen a project dial (a ticked arc you turn) filters the cards that need you. Turn the phone sideways on a board and it lies down as one kanban row, empty columns folded to rails; tap a card for its sheet with the verdict buttons.
- **Away from the Mac**: the phone shows the last boards it received. Verdicts you give are kept on the phone and
  sent, in order, when the Mac is back; a card you already decided on the Mac is skipped and named. Other changes
  need the Mac in reach (nearby, or over Tailscale) and awake.

The app is not in the App Store yet; its source is in [iOS/](iOS), built with [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## Where the data comes from

Everything is read on your Mac, and nothing is written except where the app asks first or you act on a board
yourself: a review, a note or a new card goes into that board's `KANBAN.md` as plain lines, uncommitted; a name you
give a board stays in the app's settings.

- **Boards**: every `KANBAN.md` up to three folders deep under your projects folder, which the app asks for the first
  time the board opens (`~/development` until then). Change it later from the board
  switcher's menu ("Boards Folder…"). A repository's board is its trunk checkout's
  `KANBAN.md` as it is on the disk, pushed or not; a worktree's copy counts only when the trunk has none. The app
  runs no git command.
- **Codex**: limits and sessions from `~/.codex/sessions`.
- **Claude Code**: sessions from `~/.claude/sessions` and their `subagents/` folders. Claude Code hands its
  limits only to a status line command, so the app offers to add one that saves them to a file. It asks first,
  keeps a backup of `settings.json` and never replaces an existing status line.
- **Claude limits from Anthropic** (off by default; the board switcher's menu): reads Claude Code's sign-in from
  the Keychain, which macOS asks you to allow, and asks Anthropic's usage endpoint for the two limits every three
  minutes. That endpoint is not a documented API and may stop working.

## Build

```bash
swift test
swift run notchban          # or: swift run notchban myapp, to open that board
scripts/package.sh          # Notchban.app in ./build; set NOTARY_PROFILE to sign and notarize
cd iOS && xcodegen generate # then open Notchban.xcodeproj and run on your iPhone
```

## License

MIT. See [LICENSE](LICENSE).
