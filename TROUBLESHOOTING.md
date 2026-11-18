# Troubleshooting

TopLayer depends on parts of Claude Code and Codex that it does not control, so most problems come from one of those parts being missing or having changed. This page lists the ones seen so far, with what causes each and what fixes it.

## Start here

1. Open **Settings… → Setup** from the menu bar item. It checks every piece TopLayer needs and puts a button beside anything it can repair. *Check Again* at the bottom reruns everything.
2. If Setup is all green and the problem remains, find the symptom below.
3. If it is not listed, [look at what TopLayer wrote](#seeing-what-toplayer-is-doing) before changing anything.

## Symptoms

| What you see | Go to |
|---|---|
| The welcome guide says a tool was not found | [A tool is not found](#a-tool-is-not-found) |
| "This session has not run the TopLayer hook yet" | [A Claude session can't be reached](#a-claude-session-cant-be-reached) |
| A reply is sent but Claude does nothing with it | [Claude ignores a reply](#claude-ignores-a-reply) |
| No Codex threads, or "not connected" | [Codex is not connected](#codex-is-not-connected) |
| A reply to a Codex thread takes a few seconds to appear | [A Codex reply is queued](#a-codex-reply-is-queued) |
| An agent can't send a group chat message, or the send exits with 137 | [Group chat sends fail](#group-chat-sends-fail) |
| A background Claude session can't be started | [TopLayer was started by an agent](#toplayer-was-started-by-an-agent) |
| macOS keeps asking for your login password | [macOS asks for your password](#macos-asks-for-your-password-for-toplayer-webcrypto-master-key) |
| The usage ring is empty | [The usage ring is empty](#the-usage-ring-is-empty) |
| The overlay is missing from a screenshot or a shared screen | [The overlay is not in screenshots](#the-overlay-is-not-in-screenshots) |
| A shortcut does nothing | [A shortcut does nothing](#a-shortcut-does-nothing) |
| It worked until Claude Code or Codex updated | [Something broke after an update](#something-broke-after-an-update) |
| The build or the tests fail | [The build fails](#the-build-fails) |

## A tool is not found

TopLayer looks for the commands in fixed places, not on your `PATH`:

- `claude`: `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`
- `codex`: `~/.local/bin`, `~/.codex/packages/standalone/current/bin`, `/opt/homebrew/bin`, `/usr/local/bin`

A command installed somewhere else (a version manager's folder, say) is not seen. Link it into one of those folders, then press *Check Again*:

```bash
mkdir -p ~/.local/bin && ln -s "$(command -v codex)" ~/.local/bin/codex
```

Claude counts as found if the command, the desktop app or `~/.claude` exists. Codex needs the `codex` command even when the desktop app is installed, because the command runs the background service every Codex thread goes through.

## A Claude session can't be reached

A session can be read as soon as it runs, but it can only be replied to after it has run TopLayer's hook once.

- **The hooks are not registered.** Setup shows *Hooks in Claude's settings* in red. Press *Add hooks*.
- **The session started before the hooks were added.** It becomes reachable the first time it starts or finishes a turn. Send it one message in its own window.
- **The session finished a turn and is still not reachable.** Setup lists it under *Running sessions*. The hooks may not be loading in it; restarting the session usually fixes this.
- **The session is marked read-only.** It is no longer running, so there is nothing to deliver a reply to.

The hook keeps a short log of what it did in `~/.toplayer/hook.log`: one line per event, with the first eight characters of the session id.

## Claude ignores a reply

A reply from TopLayer reaches Claude as hook feedback, which Claude Code labels as not written by the user. A session that knows nothing about TopLayer may decline to act on it, or ask you to confirm.

Add the *Note for Claude about TopLayer* in Setup. It puts a short section in `~/.claude/CLAUDE.md` that tells every session which opening line means the text is yours. Sessions read that file when they start, so a session that was already running needs a restart to see it.

## Codex is not connected

TopLayer talks to Codex's background service over a socket at `~/.codex/app-server-control/app-server-control.sock`. It starts the service by itself and retries at growing intervals; Setup has a *Start the daemon* button for when that did not work.

To try it by hand:

```bash
codex app-server daemon start
```

If that command fails, the problem is in Codex and its message says what. If it succeeds and TopLayer still shows nothing after a few seconds, see [Something broke after an update](#something-broke-after-an-update).

## A Codex reply is queued

A thread that is open in the Codex app is locked by the app. TopLayer follows such a thread through its file and puts your reply in the thread's queue, which the app picks up a few seconds later. This is expected. *Cancel queued* takes the reply back while it waits.

## Group chat sends fail

An agent sends by running `~/.toplayer/bin/toplayer-link`.

- **The send is killed with exit code 137 and prints nothing.** macOS remembers a signed program's signature by the file it is in. If a new build was written into the old file, the next run is checked against the old signature and stopped. Setup shows *Helper scripts* in red with a *Reinstall* button, which replaces the file. The build script and Setup both replace it by rename, so this should only appear after copying the file by hand.
- **A Codex thread says it has no such tool.** Setup shows *Group chat tool in Codex's config* as missing. Press *Add to Codex config*, then reopen the thread: Codex reads its config when a thread starts.
- **Codex asks you to approve every send.** Setup offers *Allow without asking*.
- **The message is held.** Each chat has its own limits (delay between messages, a message cap, approval by you). The agent gets the reason back as the result of its send, and the chat shows each message's delivery status.

## TopLayer was started by an agent

Claude Code marks every program an agent starts. If TopLayer is opened by a Claude session, for example because an agent ran `Scripts/build-app.sh --launch` for you, a Claude session TopLayer then starts would be treated as part of that session and its conversation would not be saved. TopLayer refuses to start background Claude sessions in that state and says so in the new-thread form.

Quit TopLayer and open it yourself, from Spotlight or `/Applications`. Everything else works either way.

## macOS asks for your password for TopLayer WebCrypto Master Key

The web panes (the globe buttons) keep one item in your login keychain, named *TopLayer WebCrypto Master Key*. macOS lets an app read a keychain item without asking only if it is the app that was allowed before, and it tells apps apart by who signed them.

- **Once, after changing how TopLayer is signed.** Expected: the item was allowed for the old signer. Enter your password and press **Always Allow**. *Allow* alone lets it through that one time and asks again at the next launch.
- **After every build.** The build is signed ad-hoc or with a self-signed certificate, so each build is a different program to the keychain. Sign with an Apple Development certificate instead ([README: Signing](README.md#build-and-install)); a free Apple account is enough.
- **Still asking, with an Apple certificate and after Always Allow.** This has not been needed so far, so it is untested: delete the item in Keychain Access and open a web pane again. A new one is made, belonging to the current signer. You may have to sign in to the web panes again.

The question only comes up when a web pane is opened. The rest of TopLayer does not use the keychain.

## The usage ring is empty

- **Codex.** The numbers come from the background service. If [Codex is not connected](#codex-is-not-connected), there is nothing to read.
- **Claude.** TopLayer runs `claude -p /usage` every few minutes. It needs the `claude` command installed and signed in; the desktop app's sign-in is separate and does not count. Setup shows *Plan usage* with the reason when a reading fails, and a *Try Again* button.

Anthropic marks the report that command returns as experimental, so a Claude Code update can change it. The ring then keeps its last reading and Setup says the new one could not be read.

## The overlay is not in screenshots

**Settings → General → Hide from screen sharing** keeps the overlay out of screenshots, recordings and shared screens. Turn it off to capture it.

## A shortcut does nothing

Another app has the same keys. Settings → General shows a warning under *Shortcuts* when macOS refuses one. Click the shortcut and press a different combination; it needs ⌘, ⌥ or ⌃.

## Something broke after an update

TopLayer reads Claude's session files and transcripts and speaks an experimental Codex protocol. Neither is a stable interface.

Setup shows the version of each tool that is running beside the version TopLayer was tested with. When they differ and something has stopped working, that is the likely cause:

- **Codex: "the thread list came back in a form TopLayer doesn't understand".** The protocol changed.
- **Claude: sessions are missing or show no text.** The session files or the transcript format changed.

Pull the latest TopLayer and rebuild. If it is not fixed there yet, the web panes still work: they show each product's own web client and do not depend on any of this.

## The build fails

- **macOS.** TopLayer needs macOS 26 or later.
- **Toolchain.** The Xcode Command Line Tools are enough to build (`xcode-select --install`). The tests use Swift Testing, which needs the full Xcode; `Scripts/test.sh` selects it for that one command.
- **Signing.** The script prints which identity it used. To force one, set `TOPLAYER_SIGN_IDENTITY`; to skip your certificates, set it to `-` for an ad-hoc signature.

## Seeing what TopLayer is doing

TopLayer writes its log to standard error, which is discarded when the app is opened normally. To read it, quit TopLayer and start it from a terminal:

```bash
/Applications/TopLayer.app/Contents/MacOS/TopLayer
```

Lines start with `[toplayer]`. Quit with ⌃C, then open the app normally again.

What it keeps on disk is in `~/.toplayer`. The parts worth knowing:

| Path | What it is |
|---|---|
| `bin/` | The two hook scripts and `toplayer-link` |
| `inbox/<session>/` | Replies waiting for a Claude session's hook to collect |
| `events.jsonl` | What the hooks reported: finished turns, sessions starting and ending |
| `hook.log` | The hook's own log |
| `permissions/` | Permission prompts being relayed |
| `link/` | Group chat requests from agents, and the answers |
| `groupchats.json` | Your group chats and their settings |
| `usage/` | The empty folder the Claude usage check runs in |

## Starting over

- **Run the welcome guide again:** *Welcome Guide…* in the menu bar item's menu.
- **Undo what TopLayer added:** the *Remove* buttons in Setup. Each edit also left a copy of the file as it was beside it, named `*.toplayer-backup-<time>`.
- **Forget TopLayer's own settings:** quit it, then run `defaults delete app.toplayer.TopLayer`.
- **Remove it completely:** [README: Uninstall](README.md#uninstall).
