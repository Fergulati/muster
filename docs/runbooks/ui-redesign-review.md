# Runbook: review the UI redesign (exo-720)

**For Corey, at a Linux x86_64 machine with a display. Written 2026-10-11 against `main` after PR #277.** The redesign is merged (`docs/design/ui-modernization.md`). Everything below is what no script can judge: how it looks and feels, and how it behaves inside Basecamp 0.3.2. Follow the parts in order. Each step says what to do, then **✓ Expect** what you should see. Write down the number of any step where you saw something else.

**Done 2026-10-14.** Corey ran Parts A (A1–A6) and B on `main` after #292: every step matched its ✓ Expect. Before that, a runner built from the same commit passed `scripts/ui-parity.sh` 11/11 (`MUSTER_FLEET=local`). Keep this runbook for the next review of the UI.

Budget about two hours, most of it builds. Part A is the most important; Part B can wait for another sitting.

## Already checked (nothing for you to do)

- **The gallery.** Every screen renders against data recorded from real runs, at 1024×700, 1440×900 and 1920×1080, with 0 QML warnings. The interaction fixtures check that each button calls the backend slot it should, the same calls the old UI made.
- **`scripts/ui-lint.sh`**, with its findings baseline empty.
- **The self-tests, with the new QML in the real runner**: 10 of 11 pass. `invite` fails the same way on the old UI too; it is filed (exo-e6aa) and is not for you.
- **The Nim host** (2026-10-11): `ui-nim` `contract` and `muster-app-view`, and `scripts/nim-app-core-probe.sh`, all pass. The new `Main.qml` loads in the Nim host with no QML errors, every one of its 126 `backend.*` calls is in the contract, and `muster_module.health()` answers `ok` through logos-core.
- **`scripts/basecamp-local-catalogue.sh`**, the script Part B uses. Its download, https server, certificate and isolated Basecamp profile were tested. Its build step was not, because that is the same heavy build as `make build`.

## Before you start (5 min)

1. Get the code:

   ```bash
   cd ~/muster          # your checkout
   git switch main && git pull
   git log -1 --oneline
   ```

   ✓ Expect a commit at or after the merge that added this runbook. `git status` should be clean: Part B builds from committed files only.

2. Make a folder for what you send back:

   ```bash
   mkdir -p .run/review
   ```

   Save screenshots there, named by step (`A13.png`, `B5-card.png`).

## Part A — the standalone app, two people (≈ 30 min build, 40 min looking)

### A1. Build the runner

```bash
make build
```

On your workstation this is memory-capped at 10 GB (`make help` shows the cap). If it is killed at the cap, close what you can and run it again.

Then check that the runner ships the new view:

```bash
scripts/check-runner-qml.sh
```

✓ Expect `PASS: .run/runner ships this checkout's view: 47 QML files, MusterStyle, DM Mono, 33 icons`. A `FAIL` means the build packaged the QML wrong. Stop and send the output.

### A2. Start the local chains

```bash
scripts/try-infra.sh up
```

✓ Expect anvil on 8555, with the real Safe, and bitcoind on 18453. It takes about a minute.

### A3. Two peers

In two terminals:

```bash
scripts/try-peer.sh alice --fresh
```

```bash
scripts/try-peer.sh bob --fresh
```

Make each window about 1440×900, side by side if your screen allows.

### A4. Walk through it

**The shell**

1. ✓ The left sidebar reads, top to bottom: **Muster**, **Jump to… Ctrl K**, **Needs you**, **Rooms** (with a **+**), **Join with a room code**. Near the bottom: **Wallet**, **Contacts**, **Learn**, **Settings**, and **You** with your short id.
2. Click the panel icon beside **Muster**. ✓ The sidebar collapses to a rail of icons. Click it again: it expands, and stays that way after a restart.
3. Drag a window narrower than 900 px. ✓ The sidebar becomes a drawer behind a menu button, and opens over the page. Widen the window again.
4. Press **Ctrl+K**. ✓ **Jump to a room…** opens. Typing filters, ↑ ↓ move, **Enter** opens the room, and **Esc** closes it.
5. Open **Learn**, **Settings**, **Contacts** and **Wallet** in turn. ✓ Each opens with a page header aligned with the sidebar, and a column of readable width, not stretched edge to edge.

**A room**

6. **Alice:** **Start something** → **Just talk** → pick **Bob** → **Open the room with them**. **Bob:** **Needs you** (or Home) → **Invitations** → **Join**. ✓ Within a few seconds both windows show the room. The header shows 2 faces, and under the message bar the line reads **end-to-end · 2 can read · … Who can see what**.
7. Click **Invite**. ✓ A popover shows **Invite someone** (your contacts not in the room, one click each, or a pasted contact link) and, under it, the room code with **Copy**. Click outside it to close it.
8. Click the coloured dot (**live**) in the header. ✓ A popover lists the connections (delivery, RPC), each with its state.
9. Click the room's title. ✓ It becomes editable. Type a name, press **Enter**, and the title changes on this side only.
10. Click **⋯** (More). ✓ A menu with **Room history** and **Leave room…**. Choose **Leave room…**: a dialog asks **Leave this room?**. Press **Stay**.
11. Click the room-details button (the panel icon at the right of the header). ✓ A drawer opens on the right with tabs **People**, **Accounts**, **History**, **Privacy**. Pick **History**, then close the drawer and open it again: it comes back on **History**. Narrow the window: the drawer covers the thread with a dimmed backdrop, and **Esc** closes it.
12. Send a message each way. ✓ Each arrives in the other window within about 2 s, under its sender's name.

**A decision (the card)**

13. **Alice:** click **+** beside the message bar. ✓ A picker with **Payment**, **Split a bill**, **Request a payment**, **Statement**, **Call a module**, each with an icon and a line of explanation. Choose **Statement**, type a sentence, and **Propose**. ✓ A titled panel opens above the message bar, and the thread is not pushed down. Then the card appears, **compact**:
    - its header: an icon, **Proposed a statement**, and a pill in words: **Needs you** on the side that can approve, **Waiting for 1 more** on the other;
    - the statement, and the empty approval slots with **0 of 2**;
    - one line under the slots: **✓ Checked on your device · … traced to where it came from**, with **Why?** at its end;
    - the buttons **Approve**, **Deny**, **Who sees this?** and **Details**.

    A bar under the room header names the proposal, with **Review**. **Screenshot this card (A13).**
14. Click **Details**. ✓ The card grows to show the status path (proposed · collecting · ready · final), **▸ How this account works**, the green **✓ your client re-derived this…** box, **How do I know this?**, **What this needs**, and **Download audit trail**. The button now reads **Hide details**. Open **What this needs**. ✓ It loads the needs. **Screenshot (A14)**, then click **Hide details**.
15. Click **Who sees this?** ✓ The drawer opens on **Privacy** with a chip **Showing one proposal: …** and that proposal's flow alone. The store node is always listed. Click the chip's **×**: the whole room's flow shows.
16. **Bob:** the sidebar shows a count on **Needs you**, and the room's row says it waits on him. Both **Approve**. ✓ The moment you click, the button gives way to **Sending your approval…**. The slots fill with each person's avatar, **by Alice, you** (or the reverse) appears under them, and the pill reaches **Agreed**. The other window shows a toast, **Bob approved**.
17. Propose a second statement. **Bob: Deny.** ✓ The card reads **1 declined: Bob** in amber.

**Money**

18. **A Safe payment.** **Alice:** room details → **Accounts** → **Disclose the local test Safe**. Then **+** → **Payment**: *Settles via* **Safe**, pick the account under *From*, recipient `0x90F79bf6EB2c4f870365E785982E1f101E93b906`, amount `1000000000000000` → **Propose**. Both **Approve**, then **Settle on-chain**. ✓ The card reaches **Final**, and `scripts/try-infra.sh eth balance 0x90F79bf6EB2c4f870365E785982E1f101E93b906` shows the 0.001 ETH arrived. While it collects, the compact card shows no DELEGATECALL warning, and **Details** shows the ten **How this account works** rows.
19. **A split.** **Alice:** **+** → **Split a bill**: *Settles on* **Split (Ethereum)**, total `0.02`, note `dinner`, Bob in, **✓ I'm in it too** on → **Propose**. ✓ The compact card shows the line *0.02 ETH · dinner — you paid; 1 person owes a share* and Bob's row with **to agree**. **Bob:** **Agree to my share**, then **Pay my share — 0.01 ETH**. ✓ Bob's row goes **paying…** → **paid …** → **✓ received**, and both cards reach **Final**. **Screenshot either card (A19).**

**Keyboard and feel**

20. Press **Tab** through a card and the message bar. ✓ The focused button has a visible ring, and **Enter** or **Space** presses it. With a proposal panel open, **Esc** closes it.
21. **Your judgement.** Does it read as a modern chat client? Is anything cramped, misaligned, too faint to read, or hard to find? Does anything you used often in the old UI now take more clicks? A sentence or two is plenty. Note the window size for anything layout-related.

### A5. Look for QML errors, then stop

```bash
grep -aE 'qrc:/.*(Error|error)|TypeError|ReferenceError|is not a type|Cannot assign|Property value set multiple times' \
  .run/try/alice.log .run/try/bob.log | tee .run/review/A5-qml-errors.txt
```

✓ Expect no output. Stop both peers with **Ctrl-C**, then run `scripts/try-infra.sh down`.

**Where the old right panel's contents went.** `docs/runbooks/client-tour.md` still says "right column" in places; read it as the room-details drawer:

| The tour says | Now |
|---|---|
| right column / right-hand panel → **Accounts** | room details → **Accounts** |
| **Room history** (right column) | room details → **History**, or **⋯ → Room history** |
| **Who can see what** under the history | room details → **Privacy**; the scope line's **Who can see what**; a card's **Who sees this?** |
| scope panel, **Waiting to join**, **Admit** | room details → **People**; a join request also shows in the thread with **Admit** |
| on the card: **▸ How this account works**, **What this needs**, the verify box | the card's **Details** |
| the nav bar *Home · Room · Account · Walkthrough · Settings · Contacts · Send λ* | the sidebar; **Learn** is the walkthrough, **Wallet** holds the account and **Send on LEZ** |

### A6. The polish round (exo-720.15), in the same two windows

Do these before A5's log check if you can; each is quick.

1. **Fresh start.** In a third terminal: `scripts/try-peer.sh carol --fresh`. ✓ **Needs you** briefly says **Loading your rooms…**, then shows **Getting started** with three steps and an optional one for an Ethereum account. No account warning appears above it.
2. **Share.** Carol: **Share** on the first step. ✓ A popup **Your contact link** with a name field, the link (`muster:contact/…`), **Copy link** and **QR code**. Type `Carol`, **Copy link**: the step ticks itself off.
3. **Invite by link.** Alice, in the room with Bob: **Invite** → paste Carol's link → **Invite**. ✓ A toast **Invited Carol**. Carol's Home shows the invitation; **Join**. ✓ Carol's window says **Opening the room…** (and, if it takes a while, that the first time connects to the network), never the join form.
4. **Someone new.** In Alice's room, if Carol is not in Alice's contacts: ✓ a notice **Someone new is here. Who is it?** with a name field. Type `Carol`, **Save**: the roster, the header faces and the room's name (**Bob and Carol**) use it. Unnamed people show a coloured face with no letter, never a hex digit.
5. **Messages.** Send a message. ✓ It shows at once with **Sending…** under it, which goes when it lands. Times read **just now**, **4 min ago**; a day divider sits above the first message of a day.
6. **Unread and news.** Open **Settings** in Bob's window, then have Alice send a message. ✓ Bob's sidebar shows the room in bold with a dot. Have Alice propose something: ✓ Bob gets a toast **… needs you** naming the room.
7. **Why?** Room details → **People** → **How this room is protected** → **Why?**. ✓ **Learn** opens scrolled to **Open the room**, its title highlighted.
8. **Settings.** ✓ **Basic** shows your contact link, the mixnet as three buttons (the current one lit), and Ethereum accounts as ready or not. **Advanced** adds your keys, the endpoints, delivery and RLN. The choice survives a restart.
9. **Card text** is a size larger than the page's captions; say if it is now too big.

## Part B — Muster in Basecamp 0.3.2 (≈ 20 min build, 15 min install, 15 min looking)

The new view inside the real host, installed the way a person installs it. It runs in a profile of its own, under `.run/basecamp/review/`, so your own Basecamp and its settings are not touched.

### B1. Build, serve, launch

```bash
scripts/basecamp-local-catalogue.sh --fresh
```

The first run downloads Basecamp 0.3.2 (about 290 MB) and builds `muster_module` and `muster_ui`, memory-capped like `make build`. Keep this terminal open: quitting Basecamp stops the catalogue server.

✓ Expect it to print the repository URL `https://127.0.0.1:8743/logos-repo.json`, then a Basecamp window on **Welcome to Basecamp!**.

### B2. Add the catalogue

In Basecamp: **Settings** (the bottom icon in the sidebar) → **Package Repositories** → under **Add a repository**, paste the URL → **Add**. ✓ A **Muster** entry appears under **Logos Official**.

### B3. Install

**Applications** → search `muster` → **Muster** → in **Add Application**, **untick Monero Node (local)** → **Install**. ✓ After about ten minutes the button reads **Launch**.

If it ends in **Install Failed: Download failed**: **Settings → Package Repositories → Download source: HTTP only**, then install again from **Applications**.

### B4. Launch

Press **Launch**. ✓ Muster opens inside Basecamp with its own sidebar. **Needs you** reads **Nothing waiting on you**, and a notice offers **Set up an Ethereum account**: a fresh install has nothing seeded. **Screenshot (B4).**

### B5. Walk through it inside Basecamp

One person is enough here; Part A covered two.

1. **Ctrl+K**, with Muster's view focused. ✓ Muster's **Jump to a room…** opens, not Basecamp's own search, which also uses Ctrl+K. Note which one opened.
2. Collapse and expand Muster's sidebar. ✓ It works, and does not fight Basecamp's own left bar for space.
3. **Start something** → **Just talk** → **Open the room — just you**. ✓ The room opens with its header and the scope line.
4. Open **Invite**, the connection dot, **⋯**, and the room details drawer with each of its four tabs. ✓ Every popover and menu shows whole, not clipped by Basecamp's frame. Icons are drawn: no blank squares where an icon belongs.
5. **+** → **Statement** → **Propose**. ✓ The card renders as in A13, and **Details** and **Who sees this?** work as in A14 and A15. **Screenshot the card (B5-card).**
6. Resize Basecamp's window narrow and wide. ✓ The narrow layout switches as in A3.

### B6. Logs, then quit

```bash
grep -aiE 'muster|qml' .run/basecamp/review.log .run/basecamp/review/user/logs/basecamp.log \
  | grep -aiE 'error|warning|is not a type|TypeError|ReferenceError|unavailable' \
  | head -60 | tee .run/review/B6-basecamp-errors.txt
```

✓ Expect nothing about `muster_ui` QML. Lines from other modules are fine to send too. Quit Basecamp. ✓ The terminal prints **Basecamp exited; the catalogue server is stopped.**

Run it again later without rebuilding: `scripts/basecamp-local-catalogue.sh --no-build`.

## Part C — optional, nothing for you to do

The qt-mcp acceptance harness (`ui/tests/muster-ui-test.mjs`) needs a logos-basecamp checkout with Muster baked in (`ui/tests/README.md`), which means heavy builds. If you want it, say "run the harness on bugger" and I will do it there, in a scratch clone.

## What to send back

Reply in this session with:

1. **The step numbers that did not match their ✓ Expect**, one sentence each: A1–A6 with A4's items 1–21 and A6's 1–9, and B1–B6 with B5's items 1–6. Silence about a step means it matched.
2. **The screenshots:** A13, A14, A19, B4, B5-card, plus one of anything wrong.
3. **The two log files:** `.run/review/A5-qml-errors.txt` and `.run/review/B6-basecamp-errors.txt`, even if empty.
4. **Your judgement from A4 #21.**

## If something goes wrong

| What you see | What to do |
|---|---|
| `make build` stops with "killed at the BUILD_MEM=10G cap" | Free memory and run it again. Raise `BUILD_MEM=` only if the machine can spare it. |
| `try-peer.sh`: "build the runner first" | A1 did not finish. |
| `check-runner-qml.sh` fails | The runner predates `main` (run `make build` again), or packaging lost a file. Send the output. |
| `basecamp-local-catalogue.sh`: uncommitted changes refused | Commit or stash your changes: the catalogue builds from committed files. |
| "built for another port" | Run it again without `--no-build`. |
| Port 8743 busy | Add `--port 8750` (the catalogue rebuilds for the new port). |
| "Basecamp is already running on …/review" | Quit that Basecamp first, or use another profile name: `scripts/basecamp-local-catalogue.sh review2 --fresh --no-build`. |
| Basecamp says "unsupported URL scheme" | You pasted an `http://` URL; it must be the `https://` one the script printed. |
