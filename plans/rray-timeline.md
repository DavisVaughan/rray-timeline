# rray timeline

An interactive chart for a blog post about how rray was built: almost entirely through Claude and Codex conversations, each one ending in a pull request.

The x axis is time. The y axis is the number of exported functions. Each merged PR is a dot. Clicking a dot shows when the conversations and the review behind that PR happened, with links to the PR and to a readable copy of each conversation.

Everything is built in this repo. The finished `site/` folder is then copied into the blog post.

## What the reader sees

- **The line.** A step line of the export count, from the first PR on 2026-08-28 to today. The 9 exports from the March commits pushed straight to `main` are carried in as the starting value, since the five idle months in between would otherwise take up most of the x axis. It steps up when a PR adds exports. Exports were never removed outright, only renamed, so it never steps down.

- **The dots.** One dot per merged PR (about 157), placed at its merge time and at the export count after the merge.

  - PRs that add exports get a filled dot, and every other PR gets a smaller dot. Renames count as other PRs.

- **Labels.** Only the 10 most complex PRs get a permanent label, or the top 5 on a phone. The labels tell the steering story; color and hover already cover the rest.

  - A PR that adds exports is labeled with them, like `rray_slice()` or `rray_locate_max(), rray_locate_min()`.

  - Any other PR gets a short label from `overrides.yml`, like `iterator performance`. PRs without one are never labeled.

  - Every label has a thin leader line to its dot.

  - Labels are placed most complex first, and never overlap the line, the dots, or each other. A label that can't be placed falls back to hover.

- **Overview strip.** A thin strip under the chart shows the full range. Dragging a window over it zooms the main chart. This matters in the busiest weeks (2026-W40 and W41 each had about 35 commits), which would otherwise fit into roughly 100px. The strip also works by touch, and it doesn't take over page scrolling the way scroll-to-zoom would. The y axis rescales to the exports in the window, so a busy week spreads out vertically too.

- **Complexity color.** Dot fill uses a single-hue sequential scale, light for simple PRs and dark for complex ones. PRs with no score are neutral grey. A small legend explains both. See [Complexity](#complexity).

- **Search.** A filter box at the top right fades every PR whose title, short label, or export names don't contain all of the typed words. Labels are chosen from the matches, the overview strip marks where they fall, and arrow keys step between them. A selected PR that stops matching is cleared.

- **Clicking a dot** selects that PR:

  - Other dots fade.

  - Bands appear behind the line for each stretch of conversation that led to the PR. Claude and Codex each get their own hue.

  - An outlined band shows the PR's open to merge window, with small ticks for each review you submitted.

  - A detail panel below the chart shows the PR title and a link to it, the complexity breakdown, and a list of the linked conversations. Each one has its date, length, and a link to its transcript page.

- **Deep links.** Selecting a PR sets the URL hash (`#pr-123`), so the blog text can link straight to a specific moment. Following a link zooms to fit that PR's conversations and open window, and scrolls the chart into view.

- **Keyboard and touch.** Dots are focusable, arrow keys move between PRs, Enter selects, Escape clears. On a phone, tap replaces hover.

- **Light and dark.** Colors are CSS variables that follow the Quarto theme.

- **Unshipped sessions.** Sessions that never led to a merged PR (abandoned ideas, planning on `main`) appear as faint bands in a quiet track along the bottom of the chart, with no dot. Each one links to its transcript.

### Conversation bands

A session's first and last timestamps can be days apart, with most of that time idle. A single band would overstate the work. Instead, each session splits into activity segments wherever two messages are more than 30 minutes apart, and each segment gets its own thin band. That way a reader sees "three evenings of conversation, then a PR", which is the real story.

## Rendering

A plain D3 ES module, mounted directly into the Quarto post with a raw HTML block:

````markdown
```{=html}
<div id="rray-timeline"></div>
<link rel="stylesheet" href="timeline/timeline.css">
<script type="module">
  import { mount } from "./timeline/timeline.js";
  mount("#rray-timeline", "./timeline/timeline.json");
</script>
```
````

- **Why not OJS.** The chart is one custom interaction, not a reactive notebook. OJS would add its runtime and cell styling without giving us anything D3 doesn't already do.

- **Why not an iframe.** An iframe can't share the post's fonts or theme, and its fixed height breaks on phones.

- **Development.** The same module mounts from a standalone `index.html`, so it can be built and reviewed without the blog.

- **Dependencies.** D3 from a pinned CDN version. Nothing else.

## Data pipeline

One R script, `build.R`, run by hand. It reads the rray repo, GitHub, and the local transcript stores, and writes `timeline.json` plus one HTML page per conversation.

### Inputs

| Source | Location | Used for |
|---|---|---|
| git | rray checkout | `NAMESPACE` at each merge commit |
| GitHub | `gh api graphql` | PRs, reviews, review comments, timestamps |
| Claude | `~/.claude/projects/-Users-davis-files-r-packages-rray{,4}/*.jsonl` | sessions, 173 |
| Codex | `~/.codex/{sessions,archived_sessions}/**/*.jsonl` filtered to rray `cwd` | sessions, 117 |

### Steps

1. **Exports over time.** For each merge commit on `main`, read `NAMESPACE` with `git show <sha>:NAMESPACE`, parse the `export()` lines, and diff against the previous commit. This gives the y value and the added exports for each PR. A commit that removes exports and adds the same number is a rename. Pairs come from `overrides.yml` when the order is ambiguous, as in #97. The build fails if exports are removed without being replaced, so a real removal never slips through as a rename.

2. **PRs.** Fetch every merged PR with its number, title, head branch, created, merged, and merge commit SHA, along with its reviews and comments (author, timestamp, body length).

3. **Sessions.** Stream each JSONL file and keep the session id, tool, branch(es), message timestamps, and message counts by role. Also keep token usage (Claude `usage`, Codex `token_count`) and any Claude `pr-link` events.

   - A session id is the tool plus the last 8 characters of its UUID. Codex UUIDs are v7, so their leading characters are a timestamp and collide.

   - Codex only records the branch a session started on, so branches from `git switch` and `git checkout` tool calls are added.

   - Codex `guardian_review` sessions are automated approval reviews, not conversations, and are skipped.

   - Codex `exec` sessions were started by Claude to review plans. They are kept, but their prompts don't count as yours.

   - A session with no typed prompts is skipped. Slash commands, injected context, and interrupt markers are not typed prompts.

4. **Join sessions to PRs.** In priority order:

   1. A manual `overrides.yml`, mapping session id to PR number(s), or to `null` to drop a session. It comes first so it can correct the rules below.

   2. A Claude `pr-link` event naming the PR.

   3. The session's branch matches the PR's head branch, and the session overlaps the window from the previous PR on that branch to this PR's merge. The window handles branch names that were reused.

   Today, these match 143 of 173 Claude sessions and 97 of 117 Codex sessions. The script prints the unmatched ones so they can be triaged into `overrides.yml`. Any left unmatched go in the unshipped track.

5. **Complexity.** Compute per PR, see below.

6. **Transcripts.** Render each linked session to a static HTML page. See below.

7. **Write** `timeline.json`.

### `timeline.json`

```json
{
  "generated": "2026-10-20T00:00:00Z",
  "prs": [
    {
      "number": 42,
      "title": "Add `rray_slice()`",
      "url": "https://github.com/r-lib/rray/pull/42",
      "opened": "2026-05-01T14:00:00Z",
      "merged": "2026-05-03T18:00:00Z",
      "exports": 31,
      "added": ["rray_slice"],
      "renamed": [],
      "reviews": ["2026-05-02T09:00:00Z"],
      "complexity": { "score": 0.72, "parts": { "...": "..." } },
      "sessions": ["claude-0895203c", "codex-01a0ccf1"]
    }
  ],
  "sessions": {
    "claude-0895203c": {
      "tool": "claude",
      "title": "Plan `rray_slice()`",
      "page": "transcripts/claude-0895203c.html",
      "segments": [["2026-04-29T19:00:00Z", "2026-04-29T21:10:00Z"]],
      "messages": { "user": 18, "assistant": 40 }
    }
  }
}
```

## Transcripts

One HTML page per session, styled like the post. Built from the JSONL with `commonmark` and a small page template.

- **Kept in full.** Your messages, and the agent's prose replies, rendered as markdown.

- **Collapsed.** Each tool call and its output goes in a `<details>` block whose summary is one line, like `Edit R/slice.R` or `Bash: devtools::test()`. Outputs longer than 200 lines are cut, with a note saying how much was cut.

- **Also collapsed.** Claude thinking blocks, and Claude subagent transcripts nested under the tool call that started them.

- **Removed.** System prompts, `<system-reminder>` blocks, CLAUDE.md and AGENTS.md injections, hook output, Codex `base_instructions`, Codex encrypted reasoning, and file history snapshots.

- **Redacted.** `/Users/davis` becomes `~`. A regex pass catches token-shaped strings (GitHub, OpenAI, Anthropic key prefixes). The build fails if one is found, rather than silently masking it.

- **Header.** Tool, date, linked PR(s), message counts, and a link back to the chart.

- **Approval.** You sign off on these rules once, then read a sample of rendered pages before anything is published.

## Complexity

Each PR gets a score from 0 to 1 that measures how much steering it needed. It is built from two signals:

| Signal | Meaning |
|---|---|
| Your review comments | review threads you started on the PR |
| Your messages | user turns across the linked sessions |

Agents reply to review threads and post benchmark comments under your account, so only thread roots count as yours.

Each signal becomes a percentile rank across all PRs, and the score is their mean. Percentiles keep one huge PR from flattening every other PR into the same color.

Transcripts for the earliest PRs were lost to Claude's 30 day cleanup. Those PRs have no score, are left out of the percentiles, and are drawn in a neutral grey that the legend labels as unknown.

The detail panel shows both parts, plus a few numbers for context only: conversation tokens and time from open to merge.

## Layout

```
rray-timeline/
  build.R
  overrides.yml
  site/
    index.html
    timeline.js
    timeline.css
    timeline.json
    transcripts/
```

`site/` is the folder that gets copied into the Quarto post's directory. Everything outside it is build tooling and stays here.

## Phases

1. **Data.** `build.R` steps 1 to 5, writing `timeline.json`. Review the unmatched sessions and fill in `overrides.yml`.

2. **Chart.** Line, dots, labels, axes, and complexity color in `index.html`, with no interaction yet. Check that it reads well with 157 dots.

3. **Interaction.** Overview strip, selection, bands, detail panel, hash links, keyboard and touch.

4. **Transcripts.** Rendering and redaction, then a manual read of a sample of pages before anything is published.

5. **Blog.** Mount into the Quarto post and check light, dark, and phone widths.
