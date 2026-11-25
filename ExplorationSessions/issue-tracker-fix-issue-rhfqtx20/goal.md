Your task is this one issue, OBMP-125: [Bot] [SDK] OnAreaDeleted and OnCellDeleted server events never fire

Summary:
Reported by Merlin (Tales from Nirn) on SDK 1.0.0-rc.2: the server events OnAreaDeleted and OnCellDeleted are declared in IServerEvents but never fire. The guide says the server keeps every area and cell, so they can never be raised.

Verification Builds: not verified

Expected outcome:
Either the events fire when an area or cell is removed, or, if areas and cells are never removed, the events are removed from the API (or marked obsolete) and the docs say so.

Actual outcome:
The events are part of the public API but are never raised, so mod code subscribed to them never runs.

Source: https://readycodeio.slack.com/archives/C0C9ASV6J76/p1792497059870319

## What to do

Reproduce the issue before you fix it, wherever you can. Then fix it, within the line the scope examples below draw, and test it.

Two endings produce no fix, and both are good outcomes. Never invent work to have something to show.

- The issue already works, or is not an issue. Say so, with what you checked. This ends as `already-works`.
- The issue needs something significant outside this issue first: another issue, a missing system or capability, a decision nobody has made. Saying so accurately is better than building that thing without consultation. This ends as `blocked`, naming what blocks it (its Jira key when it is an issue). You never start on other issues and never build the missing piece.

## Where the line falls in this repository

This repository has no scope examples, so use your judgment about where this issue's line falls, and say what you decided in your write-up.

## What your change will be judged on

A separate reviewer, who has no attachment to your work, reads your change against these criteria. They say what the review looks at and why it matters.

This repository has no ReviewGate criteria, so nothing is written down about what its review looks at. Use the repository's own docs and the existing code as your guide.

## Earlier attempts

There are no earlier attempts at this issue.

## Along the way

Keep track of each escalation (what you could not decide or do alone, and why) and each discovery (what you learned that the next person should know): you report them when you end. The issue's comments and links are in Jira, which is for reading only: you never change an issue.

## What you have here

You work in the folder you are in: a clone of `julkiewicz/readymp-docs`, the fork of the person this attempt runs for, on the branch `issue-tracker-fix-issue-rhfqtx20`.

You read and push only this fork, and only the branch `issue-tracker-fix-issue-rhfqtx20`. `gh` reaches GitHub as the person this attempt runs for, for this fork. Other repositories are not reachable from here: what the run needs from them, such as a build's result and its log, it gives you.