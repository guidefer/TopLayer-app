# Contributing

This repository is a published copy of TopLayer. Development happens in a separate, private repository, and this one is updated from it a version at a time. That shapes how changes get in.

## Reporting a problem

Check [TROUBLESHOOTING.md](TROUBLESHOOTING.md) first: most problems come from a hook, a config entry or a tool version, and the Setup tab can repair them.

If it is not there, open an issue with:

- what you did and what happened instead
- your macOS version, and the Claude Code and Codex versions the Setup tab shows
- the lines TopLayer wrote, if you can get them ([how](TROUBLESHOOTING.md#seeing-what-toplayer-is-doing))

Leave out anything private. TopLayer's log and `~/.toplayer` can hold thread titles and message text.

## Proposing a change

Pull requests are welcome. An accepted one is applied to the development repository by hand and arrives here with the next published version, so your pull request is closed with a note, not merged. Your authorship is kept in the commit.

Before opening one:

1. Run the tests: `Scripts/test.sh` (needs the full Xcode).
2. Never point a test or an installer at the real `~/.claude` or `~/.codex` files. Every installer takes its paths as parameters; the tests use scratch copies.
3. Keep a change to one thing. A fix and a new feature are two pull requests.

For anything larger than a fix, open an issue first so the direction can be agreed before you write it.
