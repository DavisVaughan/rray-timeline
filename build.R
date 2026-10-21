# Builds `site/timeline.json` from the rray repo, GitHub, and local transcripts
#
# Run from the root of this repo with `Rscript build.R`

rray_path <- path.expand("~/files/r/packages/rray")
rray_ref <- "origin/main"
rray_owner <- "r-lib"
rray_name <- "rray"
me <- "DavisVaughan"

claude_dirs <- path.expand(c(
  "~/.claude/projects/-Users-davis-files-r-packages-rray",
  "~/.claude/projects/-Users-davis-files-r-packages-rray4"
))
codex_dirs <- path.expand(c(
  "~/.codex/sessions",
  "~/.codex/archived_sessions"
))
codex_cwds <- c(
  "/Users/davis/files/r/packages/rray",
  "/Users/davis/files/r/packages/rray4"
)
pr_link_repos <- c("r-lib/rray", "DavisVaughan/rray4")

segment_gap <- 30 * 60

# Prompts too empty to title a session with
greetings <- c("hi", "hello", "hey", "you there")

# Sessions started with this prompt are titled `review_title`
review_prompt <- "Address all GitHub PR comments one by one"
review_title <- "/gh-pr-review"

title_width <- 72L

# Relative to a transcript page, assuming the chart's page sits one level above `site/`
chart_url <- "../../"

me_label <- "Davis"
tool_labels <- c(claude = "Claude", codex = "Codex")

transcript_lines <- 200L
summary_width <- 100L

# Names for the tools that Codex scripts call
codex_tool_labels <- c(
  exec_command = "Bash",
  write_stdin = "Wait for output",
  web__run = "Web"
)

# Local commands that say nothing about the work
hidden_commands <- c("/clear", "/context", "/exit", "/login", "/usage")

# GitHub, Anthropic, and OpenAI key prefixes
secret_pattern <- paste0(
  "\\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{22,}|",
  "sk-ant-[A-Za-z0-9_-]{20,}|sk-(?:proj-)?[A-Za-z0-9_-]{20,})"
)

main <- function() {
  overrides <- yaml::read_yaml("overrides.yml")

  commits <- read_commits(overrides$renames)
  prs <- read_prs()
  sessions <- read_sessions()

  dropped <- names(Filter(is.null, overrides$sessions))
  sessions <- sessions[!names(sessions) %in% dropped]
  sessions <- retitle(sessions, overrides$titles)

  links <- link_sessions(sessions, prs, compact(overrides$sessions))
  report_unmatched(sessions, links)

  timeline <- build_timeline(commits, prs, sessions, links, overrides$labels)
  write_transcripts(sessions, prs, links)

  dir.create("site", showWarnings = FALSE)
  jsonlite::write_json(
    timeline,
    "site/timeline.json",
    auto_unbox = TRUE,
    pretty = TRUE,
    null = "null"
  )

  cli::cli_alert_success(paste(
    "Wrote {.file site/timeline.json}:",
    "{length(timeline$prs)} PRs,",
    "{length(timeline$commits)} commits,",
    "{length(timeline$sessions)} sessions and their transcripts"
  ))
}

# ------------------------------------------------------------------------------
# Exports

read_commits <- function(renames) {
  log <- git(
    "log",
    "--first-parent",
    "--reverse",
    "--format=%H%x09%ct%x09%s",
    rray_ref
  )
  log <- strsplit(log, "\t", fixed = TRUE)

  previous <- character()
  out <- vector("list", length(log))

  for (i in seq_along(log)) {
    sha <- log[[i]][[1]]
    current <- read_exports(sha)

    added <- setdiff(current, previous)
    removed <- setdiff(previous, current)
    pairs <- rename_pairs(sha, added, removed, renames)

    out[[i]] <- list(
      sha = sha,
      date = .POSIXct(as.numeric(log[[i]][[2]]), tz = "UTC"),
      title = log[[i]][[3]],
      exports = length(current),
      added = setdiff(added, pairs$to),
      renamed = pairs
    )

    previous <- current
  }

  out
}

read_exports <- function(sha) {
  namespace <- git("show", paste0(sha, ":NAMESPACE"), error_on_status = FALSE)
  exports <- regmatches(
    namespace,
    regexpr("(?<=^export\\().+(?=\\)$)", namespace, perl = TRUE)
  )
  gsub("^[\"`]|[\"`]$", "", exports)
}

# Pairs each removed export with the export that replaced it
rename_pairs <- function(sha, added, removed, renames) {
  if (length(removed) == 0L) {
    return(data.frame(from = character(), to = character()))
  }

  key <- names(renames)[startsWith(sha, names(renames))]

  if (length(key) == 1L) {
    pairs <- renames[[key]]
    pairs <- data.frame(
      from = names(pairs),
      to = unlist(pairs, use.names = FALSE)
    )
  } else if (length(removed) == 1L && length(added) == 1L) {
    pairs <- data.frame(from = removed, to = added)
  } else {
    cli::cli_abort(c(
      "Commit {.val {substr(sha, 1, 7)}} removes exports and the renames are ambiguous.",
      "i" = "Removed: {.fn {removed}}",
      "i" = "Added: {.fn {added}}",
      "i" = "Pair them under {.field renames} in {.file overrides.yml}."
    ))
  }

  if (!setequal(pairs$from, removed) || !all(pairs$to %in% added)) {
    cli::cli_abort(c(
      "Commit {.val {substr(sha, 1, 7)}} removes exports without replacing them.",
      "i" = "Removed: {.fn {removed}}",
      "i" = "Added: {.fn {added}}"
    ))
  }

  pairs
}

# ------------------------------------------------------------------------------
# GitHub

pr_query <- '
query($owner: String!, $name: String!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(states: MERGED, first: 25, after: $endCursor) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number
        title
        url
        headRefName
        createdAt
        mergedAt
        mergeCommit { oid }
        reviews(first: 100) {
          totalCount
          nodes {
            state
            submittedAt
            author { login }
            comments(first: 100) {
              totalCount
              nodes { replyTo { id } }
            }
          }
        }
      }
    }
  }
}
'

read_prs <- function() {
  pages <- gh_graphql(pr_query, owner = rray_owner, name = rray_name)
  nodes <- unlist(
    lapply(pages, function(page) page$data$repository$pullRequests$nodes),
    recursive = FALSE
  )

  prs <- lapply(nodes, function(node) {
    reviews <- node$reviews
    if (reviews$totalCount > length(reviews$nodes)) {
      cli::cli_abort("PR #{node$number} has more reviews than were fetched.")
    }

    # Agents reply to review threads under my account, so only thread roots are mine
    roots <- vapply(
      reviews$nodes,
      function(review) {
        if (review$state == "PENDING" || !identical(review$author$login, me)) {
          return(0L)
        }
        if (review$comments$totalCount > length(review$comments$nodes)) {
          cli::cli_abort(
            "A review on PR #{node$number} has more comments than were fetched."
          )
        }
        sum(vapply(
          review$comments$nodes,
          function(comment) is.null(comment$replyTo),
          logical(1)
        ))
      },
      integer(1)
    )

    submitted <- vapply(
      reviews$nodes,
      function(review) review$submittedAt %||% NA_character_,
      character(1)
    )

    list(
      number = node$number,
      title = node$title,
      url = node$url,
      head = node$headRefName,
      opened = parse_time(node$createdAt),
      merged = parse_time(node$mergedAt),
      sha = node$mergeCommit$oid,
      reviews = sort(parse_time(submitted[roots > 0L])),
      review_comments = sum(roots)
    )
  })

  prs[order(vapply(prs, function(pr) as.numeric(pr$merged), numeric(1)))]
}

gh_graphql <- function(query, ...) {
  fields <- list(...)
  args <- c(
    "api",
    "graphql",
    "--paginate",
    "--slurp",
    "-f",
    paste0("query=", query),
    unlist(Map(
      function(name, value) c("-F", paste0(name, "=", value)),
      names(fields),
      fields
    ))
  )
  out <- processx::run("gh", args)$stdout
  jsonlite::parse_json(out)
}

# ------------------------------------------------------------------------------
# Sessions

read_sessions <- function() {
  claude <- lapply(
    list_jsonl(claude_dirs, recursive = FALSE),
    read_claude_session
  )
  codex <- lapply(list_jsonl(codex_dirs, recursive = TRUE), read_codex_session)
  sessions <- c(compact(claude), compact(codex))

  ids <- vapply(sessions, function(session) session$id, character(1))
  if (anyDuplicated(ids)) {
    cli::cli_abort(
      "Session ids collide: {.val {unique(ids[duplicated(ids)])}}."
    )
  }

  names(sessions) <- ids
  sessions[order(vapply(
    sessions,
    function(session) as.numeric(session$start),
    numeric(1)
  ))]
}

read_claude_session <- function(path) {
  uuid <- sub("\\.jsonl$", "", basename(path))
  entries <- claude_entries(path)

  messages <- Filter(
    function(entry) is_type(entry, c("user", "assistant")),
    entries
  )
  if (length(messages) == 0L) {
    return(NULL)
  }

  users <- Filter(
    function(entry) is_type(entry, "user") && !isTRUE(entry$isMeta),
    messages
  )
  prompts <- unlist(lapply(users, function(entry) {
    claude_prompt(entry$message$content)
  }))

  assistants <- Filter(function(entry) is_type(entry, "assistant"), messages)
  replies <- Filter(
    function(entry) has_text_block(entry$message$content),
    assistants
  )

  # Streamed replies repeat the same usage once per content block
  usage <- lapply(assistants, function(entry) entry$message$usage)
  usage <- usage[
    !duplicated(vapply(
      assistants,
      function(entry) entry$message$id %||% NA_character_,
      character(1)
    ))
  ]

  links <- Filter(
    function(entry) {
      is_type(entry, "pr-link") && isTRUE(entry$prRepository %in% pr_link_repos)
    },
    entries
  )

  new_session(
    tool = "claude",
    uuid = uuid,
    path = path,
    cwd = Find(Negate(is.null), lapply(messages, function(entry) entry$cwd)),
    times = vapply(messages, function(entry) entry$timestamp, character(1)),
    branches = vapply(
      messages,
      function(entry) entry$gitBranch %||% NA_character_,
      character(1)
    ),
    prompts = prompts,
    replies = length(unique(vapply(
      replies,
      function(entry) entry$message$id,
      character(1)
    ))),
    input_tokens = sum_field(
      usage,
      c(
        "input_tokens",
        "cache_creation_input_tokens",
        "cache_read_input_tokens"
      )
    ),
    output_tokens = sum_field(usage, "output_tokens"),
    pr_links = vapply(
      links,
      function(entry) as.integer(entry$prNumber),
      integer(1)
    ),
    agent = FALSE
  )
}

read_codex_session <- function(path) {
  entries <- read_jsonl(path)

  meta <- Find(function(entry) is_type(entry, "session_meta"), entries)$payload
  if (
    !isTRUE(meta$cwd %in% codex_cwds) ||
      identical(meta$thread_source, "guardian_review")
  ) {
    return(NULL)
  }

  messages <- Filter(
    function(entry) {
      is_type(entry, "response_item") &&
        identical(entry$payload$type, "message") &&
        isTRUE(entry$payload$role %in% c("user", "assistant"))
    },
    entries
  )
  if (length(messages) == 0L) {
    return(NULL)
  }

  roles <- vapply(messages, function(entry) entry$payload$role, character(1))
  texts <- vapply(
    messages,
    function(entry) {
      paste(
        vapply(
          entry$payload$content,
          function(block) block$text %||% "",
          character(1)
        ),
        collapse = ""
      )
    },
    character(1)
  )

  calls <- Filter(
    function(entry) {
      is_type(entry, "response_item") &&
        isTRUE(entry$payload$type %in% c("function_call", "custom_tool_call"))
    },
    entries
  )
  commands <- vapply(
    calls,
    function(entry) paste(entry$payload$arguments, entry$payload$input),
    character(1)
  )

  usage <- Filter(
    function(entry) {
      identical(entry$payload$type, "token_count") &&
        !is.null(entry$payload$info)
    },
    entries
  )
  usage <- if (length(usage)) {
    usage[[length(usage)]]$payload$info$total_token_usage
  } else {
    list()
  }

  new_session(
    tool = "codex",
    uuid = meta$id,
    path = path,
    cwd = meta$cwd,
    times = vapply(messages, function(entry) entry$timestamp, character(1)),
    # Codex only records the branch a session started on
    branches = c(
      meta$git$branch %||% NA_character_,
      switched_branches(commands)
    ),
    prompts = Filter(is_prompt, texts[roles == "user"]),
    replies = sum(roles == "assistant"),
    input_tokens = usage$input_tokens %||% 0,
    output_tokens = usage$output_tokens %||% 0,
    pr_links = integer(),
    # `codex exec` sessions were started by Claude to review plans
    agent = identical(meta$source, "exec")
  )
}

new_session <- function(
  tool,
  uuid,
  path,
  cwd,
  times,
  branches,
  prompts,
  replies,
  input_tokens,
  output_tokens,
  pr_links,
  agent
) {
  times <- sort(parse_time(times))
  branches <- unique(branches[
    !is.na(branches) & branches != "" & branches != "HEAD"
  ])

  if (length(prompts) == 0L && !agent) {
    return(NULL)
  }

  list(
    # The tail is random in both UUIDv4 (Claude) and UUIDv7 (Codex)
    id = paste0(tool, "-", substr(uuid, nchar(uuid) - 7L, nchar(uuid))),
    tool = tool,
    agent = agent,
    path = path,
    cwd = cwd,
    title = session_title(prompts),
    branches = branches,
    start = times[[1L]],
    end = times[[length(times)]],
    segments = segment(times),
    prompts = length(prompts),
    replies = replies,
    tokens = input_tokens + output_tokens,
    pr_links = unique(pr_links)
  )
}

# Some sessions carry copies of other sessions' entries
claude_entries <- function(path) {
  uuid <- sub("\\.jsonl$", "", basename(path))
  Filter(
    function(entry) {
      !isTRUE(entry$isSidechain) &&
        (is.null(entry$sessionId) || identical(entry$sessionId, uuid))
    },
    read_jsonl(path)
  )
}

# Text I typed, or `NULL` for tool results and injected context
claude_prompt <- function(content) {
  if (is.character(content)) {
    text <- content
  } else {
    types <- vapply(content, function(block) block$type, character(1))
    if (any(types == "tool_result")) {
      return(NULL)
    }
    text <- paste(
      vapply(
        content[types == "text"],
        function(block) block$text,
        character(1)
      ),
      collapse = ""
    )
  }

  if (is_prompt(text)) text else NULL
}

is_prompt <- function(text) {
  text <- trimws(text)
  nzchar(text) &&
    !startsWith(text, "<") &&
    !startsWith(text, "# AGENTS.md instructions") &&
    !startsWith(text, "[Request interrupted")
}

switched_branches <- function(commands) {
  matches <- regmatches(
    commands,
    gregexpr(
      "git (?:switch|checkout)(?: -[bcC])? \\K[A-Za-z0-9_./-]+",
      commands,
      perl = TRUE
    )
  )
  branches <- unique(as.character(unlist(matches)))
  branches[!startsWith(branches, "-")]
}

has_text_block <- function(content) {
  any(vapply(
    content,
    function(block) identical(block$type, "text"),
    logical(1)
  ))
}

session_title <- function(prompts) {
  if (length(prompts) == 0L) {
    return(NA_character_)
  }
  substantive <- Filter(Negate(is_greeting), prompts)
  prompt <- if (length(substantive)) substantive[[1L]] else prompts[[1L]]
  if (startsWith(trimws(prompt), review_prompt)) {
    return(review_title)
  }
  lines <- strsplit(trimws(prompt), "\n", fixed = TRUE)[[1L]]
  ellipsize(trimws(lines[[1L]]), title_width)
}

retitle <- function(sessions, titles) {
  unknown <- setdiff(names(titles), names(sessions))
  if (length(unknown)) {
    cli::cli_abort(
      "{.file overrides.yml} titles unknown sessions: {.val {unknown}}."
    )
  }

  long <- names(titles)[nchar(unlist(titles)) > title_width]
  if (length(long)) {
    cli::cli_abort(
      "{.file overrides.yml} titles are over {title_width} characters: {.val {long}}."
    )
  }

  for (id in names(titles)) {
    sessions[[id]]$title <- titles[[id]]
  }
  sessions
}

is_greeting <- function(prompt) {
  words <- trimws(gsub("[[:punct:][:space:]]+", " ", tolower(prompt)))
  words %in% greetings
}

# Splits sorted times into stretches with no gap longer than `segment_gap`
segment <- function(times) {
  breaks <- which(diff(as.numeric(times)) > segment_gap)
  starts <- c(1L, breaks + 1L)
  ends <- c(breaks, length(times))
  lapply(seq_along(starts), function(i) times[c(starts[[i]], ends[[i]])])
}

# ------------------------------------------------------------------------------
# Linking

link_sessions <- function(sessions, prs, overrides) {
  unknown <- setdiff(names(overrides), names(sessions))
  if (length(unknown)) {
    cli::cli_abort(
      "{.file overrides.yml} names unknown sessions: {.val {unknown}}."
    )
  }

  numbers <- vapply(prs, function(pr) pr$number, integer(1))
  heads <- vapply(prs, function(pr) pr$head, character(1))
  merged <- vapply(prs, function(pr) as.numeric(pr$merged), numeric(1))

  # A reused branch name only matches sessions after its previous PR merged
  previous <- match_previous(heads)
  opened <- ifelse(is.na(previous), -Inf, merged[previous])

  lapply(sessions, function(session) {
    if (session$id %in% names(overrides)) {
      linked <- as.integer(unlist(overrides[[session$id]]))
      if (!all(linked %in% numbers)) {
        cli::cli_abort(
          "{.file overrides.yml} links {.field {session$id}} to an unknown PR."
        )
      }
      return(linked)
    }

    # Links to PRs merged before the session started are only references
    current <- numbers[merged >= as.numeric(session$start)]
    linked <- intersect(session$pr_links, current)
    if (length(linked)) {
      return(linked)
    }

    overlaps <- as.numeric(session$end) >= opened &
      as.numeric(session$start) <= merged
    numbers[heads %in% session$branches & overlaps]
  })
}

# Index of the previous PR with the same head branch, or `NA`
match_previous <- function(heads) {
  vapply(
    seq_along(heads),
    function(i) {
      previous <- which(heads[seq_len(i - 1L)] == heads[[i]])
      if (length(previous)) previous[[length(previous)]] else NA_integer_
    },
    integer(1)
  )
}

report_unmatched <- function(sessions, links) {
  unmatched <- sessions[lengths(links) == 0L]
  if (length(unmatched) == 0L) {
    return(invisible())
  }

  cli::cli_alert_info("{length(unmatched)} session{?s} did not match a PR:")
  for (session in unmatched) {
    branches <- if (length(session$branches)) {
      paste(session$branches, collapse = ", ")
    } else {
      "no branch"
    }
    cli::cli_text(
      "{.field {session$id}} {format(session$start, '%Y-%m-%d')} ",
      "[{branches}] {session$title}"
    )
  }
}

# ------------------------------------------------------------------------------
# Output

build_timeline <- function(commits, prs, sessions, links, labels) {
  numbers <- vapply(prs, function(pr) pr$number, integer(1))

  unknown <- setdiff(names(labels), numbers)
  if (length(unknown)) {
    cli::cli_abort(
      "{.file overrides.yml} labels unknown PRs: {.val {unknown}}."
    )
  }

  commit_shas <- vapply(commits, function(commit) commit$sha, character(1))
  pr_shas <- vapply(prs, function(pr) pr$sha, character(1))

  missing <- setdiff(pr_shas, commit_shas)
  if (length(missing)) {
    cli::cli_abort(c(
      "{length(missing)} merged PR{?s} {?is/are} not on {.val {rray_ref}}.",
      "i" = "Fetch in {.path {rray_path}} and rebuild."
    ))
  }

  session_prs <- invert(links, numbers)
  complexity <- compute_complexity(prs, sessions, session_prs)

  pr_out <- Map(
    function(pr, complexity) {
      commit <- commits[[match(pr$sha, commit_shas)]]
      list(
        number = pr$number,
        title = pr$title,
        label = labels[[as.character(pr$number)]],
        url = pr$url,
        opened = format_time(pr$opened),
        merged = format_time(pr$merged),
        exports = commit$exports,
        added = I(commit$added),
        renamed = commit$renamed,
        reviews = I(format_time(pr$reviews)),
        complexity = complexity,
        sessions = I(session_prs[[as.character(pr$number)]])
      )
    },
    prs,
    complexity
  )

  direct <- Filter(
    function(commit) {
      !commit$sha %in% pr_shas && (length(commit$added) || nrow(commit$renamed))
    },
    commits
  )
  commit_out <- lapply(direct, function(commit) {
    list(
      sha = commit$sha,
      title = commit$title,
      url = sprintf(
        "https://github.com/%s/%s/commit/%s",
        rray_owner,
        rray_name,
        commit$sha
      ),
      date = format_time(commit$date),
      exports = commit$exports,
      added = I(commit$added),
      renamed = commit$renamed
    )
  })

  session_out <- lapply(sessions, function(session) {
    list(
      tool = session$tool,
      agent = session$agent,
      title = session$title,
      page = page_path(session$id),
      segments = lapply(session$segments, format_time),
      messages = list(user = session$prompts, assistant = session$replies),
      tokens = session$tokens,
      prs = I(links[[session$id]])
    )
  })

  list(
    generated = format_time(Sys.time()),
    prs = pr_out,
    commits = commit_out,
    sessions = session_out
  )
}

# Each PR's score is the mean percentile rank of how much I steered it
compute_complexity <- function(prs, sessions, session_prs) {
  linked <- lapply(prs, function(pr) {
    sessions[session_prs[[as.character(pr$number)]]]
  })

  review_comments <- vapply(prs, function(pr) pr$review_comments, integer(1))
  messages <- vapply(
    linked,
    function(group) {
      sum(vapply(
        group,
        function(session) if (session$agent) 0L else session$prompts,
        integer(1)
      ))
    },
    integer(1)
  )
  tokens <- vapply(
    linked,
    function(group) {
      sum(vapply(group, function(session) session$tokens, numeric(1)))
    },
    numeric(1)
  )
  hours <- vapply(
    prs,
    function(pr) as.numeric(difftime(pr$merged, pr$opened, units = "hours")),
    numeric(1)
  )

  # PRs whose transcripts were lost have no score
  known <- lengths(linked) > 0L

  score <- rep(NA_real_, length(prs))
  score[known] <- (percent_rank(review_comments[known]) +
    percent_rank(messages[known])) /
    2

  Map(
    function(known, score, review_comments, messages, tokens, hours) {
      list(
        score = if (known) round(score, 3) else NULL,
        parts = list(
          review_comments = review_comments,
          messages = if (known) messages else NULL
        ),
        context = list(
          tokens = if (known) tokens else NULL,
          open_hours = round(hours, 1)
        )
      )
    },
    known,
    score,
    review_comments,
    messages,
    tokens,
    hours
  )
}

percent_rank <- function(x) {
  (rank(x, ties.method = "average") - 1) / (length(x) - 1)
}

# Turns session -> PR links into PR number -> session ids
invert <- function(links, numbers) {
  ids <- rep(names(links), lengths(links))
  linked <- unlist(links, use.names = FALSE)
  out <- lapply(numbers, function(number) ids[linked %in% number])
  names(out) <- numbers
  out
}

# ------------------------------------------------------------------------------
# Transcripts

page_path <- function(id) {
  paste0("transcripts/", id, ".html")
}

write_transcripts <- function(sessions, prs, links) {
  dir.create("site/transcripts", showWarnings = FALSE)
  unlink(list.files(
    "site/transcripts",
    pattern = "\\.html$",
    full.names = TRUE
  ))

  urls <- vapply(prs, function(pr) pr$url, character(1))
  names(urls) <- vapply(prs, function(pr) pr$number, integer(1))

  for (session in sessions) {
    items <- switch(
      session$tool,
      claude = claude_items(
        claude_entries(session$path),
        session$cwd,
        claude_subagents(session$path)
      ),
      codex = codex_items(read_jsonl(session$path), session$cwd)
    )
    page <- transcript_page(session, items, links[[session$id]], urls)
    page <- redact(page, session$id)
    writeLines(page, file.path("site", page_path(session$id)), useBytes = TRUE)
  }
}

transcript_page <- function(session, items, prs, urls) {
  title <- if (is.na(session$title)) "Untitled session" else session$title

  pr_links <- vapply(
    prs,
    function(number) {
      sprintf('<a href="%s">#%d</a>', urls[[as.character(number)]], number)
    },
    character(1)
  )
  back <- if (length(prs)) {
    sprintf("%s#pr-%d", chart_url, prs[[1L]])
  } else {
    chart_url
  }

  facts <- c(
    tool_labels[[session$tool]],
    if (session$agent) "started by Claude",
    format_day(session$start),
    plural(session$prompts, "prompt", "prompts"),
    plural(session$replies, "reply", "replies"),
    if (length(prs)) paste(pr_links, collapse = ", ") else "didn't ship"
  )

  labels <- c(
    user = if (session$agent) "Claude" else me_label,
    assistant = tool_labels[[session$tool]]
  )

  paste0(
    '<!doctype html>\n<html lang="en">\n<head>\n',
    '<meta charset="utf-8">\n',
    '<meta name="viewport" content="width=device-width, initial-scale=1">\n',
    "<title>",
    html_escape(gsub("`", "", title, fixed = TRUE)),
    "</title>\n",
    '<link rel="icon" href="data:,">\n',
    '<link rel="stylesheet" href="transcript.css">\n',
    sprintf('</head>\n<body class="%s">\n<header>\n', session$tool),
    sprintf('<a class="back" href="%s">rray timeline</a>\n', back),
    "<h1>",
    inline_html(title),
    "</h1>\n",
    '<p class="facts">',
    paste(facts, collapse = " · "),
    "</p>\n</header>\n<main>\n",
    render_turns(items, labels),
    "\n</main>\n</body>\n</html>"
  )
}

# Groups items into turns, with a divider wherever the conversation went idle
render_turns <- function(items, labels, dividers = TRUE) {
  out <- character()
  role <- NULL
  last <- NA_real_

  for (item in items) {
    time <- as.numeric(item$time)
    gap <- dividers &&
      !is.na(time) &&
      (is.na(last) || time - last > segment_gap)

    if (gap || !identical(item$role, role)) {
      if (!is.null(role)) {
        out <- c(out, "</section>")
      }
      if (gap) {
        out <- c(
          out,
          sprintf('<p class="divider">%s</p>', format_minute(item$time))
        )
      }
      out <- c(
        out,
        sprintf(
          '<section class="turn turn-%s">\n<p class="who">%s</p>',
          item$role,
          labels[[item$role]]
        )
      )
      role <- item$role
    }

    if (!is.na(time)) {
      last <- time
    }
    out <- c(out, item$html)
  }

  if (!is.null(role)) {
    out <- c(out, "</section>")
  }
  paste(out, collapse = "\n")
}

new_item <- function(role, time, html) {
  list(role = role, time = time, html = html)
}

prose_item <- function(role, time, text) {
  if (!nzchar(trimws(text))) {
    return(NULL)
  }
  new_item(role, time, markdown(text, hardbreaks = role == "user"))
}

thinking_item <- function(time, text) {
  if (!nzchar(trimws(text))) {
    return(NULL)
  }
  new_item(
    "assistant",
    time,
    paste0(
      '<details class="thinking"><summary>Thinking</summary>\n',
      markdown(text),
      "</details>"
    )
  )
}

tool_html <- function(summary, input, output, error = FALSE, children = NULL) {
  paste0(
    '<details class="tool',
    if (error) " tool-error",
    '"><summary>',
    html_escape(ellipsize(summary, summary_width)),
    "</summary>\n",
    paste(input, collapse = "\n"),
    children,
    if (length(output) && nzchar(output)) pre_html(output, "output"),
    "</details>"
  )
}

# ------------------------------------------------------------------------------
# Claude transcripts

claude_items <- function(entries, cwd, subagents = character()) {
  results <- claude_results(entries)

  items <- lapply(entries, function(entry) {
    if (is_type(entry, "assistant")) {
      time <- parse_time(entry$timestamp)
      lapply(entry$message$content, function(block) {
        switch(
          block$type,
          text = prose_item("assistant", time, block$text),
          thinking = thinking_item(time, block$thinking %||% ""),
          tool_use = new_item(
            "assistant",
            time,
            claude_tool_html(block, results[[block$id]], cwd, subagents)
          )
        )
      })
    } else if (is_type(entry, "user") && !isTRUE(entry$isMeta)) {
      time <- parse_time(entry$timestamp)
      content <- entry$message$content
      prompt <- claude_prompt(content)
      if (!is.null(prompt)) {
        return(list(prose_item("user", time, prompt)))
      }
      command <- claude_command(content)
      if (!is.null(command)) {
        return(list(new_item("user", time, command)))
      }
      NULL
    }
  })

  compact(unlist(items, recursive = FALSE))
}

# Tool results by the id of the call they answer
claude_results <- function(entries) {
  results <- list()
  for (entry in entries) {
    content <- entry$message$content
    if (!is_type(entry, "user") || !is.list(content)) {
      next
    }
    for (block in content) {
      if (identical(block$type, "tool_result")) {
        results[[block$tool_use_id]] <- list(
          text = claude_result_text(block$content),
          error = isTRUE(block$is_error)
        )
      }
    }
  }
  results
}

claude_result_text <- function(content) {
  if (is.list(content)) {
    content <- vapply(
      content,
      function(block) {
        switch(
          block$type,
          text = block$text,
          image = "[image]",
          tool_reference = block$tool_name %||% "",
          ""
        )
      },
      character(1)
    )
    content <- paste(content[nzchar(content)], collapse = "\n")
  }
  content <- content %||% ""

  # Large outputs are saved next to the session, with only a stub inline
  saved <- regmatches(
    content,
    regexec("Full output saved to: (\\S+)", content)
  )[[1L]]
  if (length(saved) && file.exists(saved[[2L]])) {
    content <- paste(
      readLines(saved[[2L]], warn = FALSE, encoding = "UTF-8"),
      collapse = "\n"
    )
  }

  content
}

# Subagent transcripts by the id of the tool call that started them
claude_subagents <- function(path) {
  dir <- file.path(sub("\\.jsonl$", "", path), "subagents")
  metas <- list.files(dir, pattern = "\\.meta\\.json$", full.names = TRUE)
  ids <- vapply(
    metas,
    function(meta) jsonlite::read_json(meta)$toolUseId %||% NA_character_,
    character(1)
  )
  stats::setNames(sub("\\.meta\\.json$", ".jsonl", metas), ids)
}

claude_command <- function(content) {
  if (!is.character(content)) {
    return(NULL)
  }
  name <- regmatches(
    content,
    regexec("<command-name>(/[^<]+)</command-name>", content)
  )[[1L]]
  if (length(name) == 0L || name[[2L]] %in% hidden_commands) {
    return(NULL)
  }
  args <- regmatches(
    content,
    regexec("<command-args>([^<]*)</command-args>", content)
  )[[1L]]
  args <- if (length(args)) trimws(args[[2L]]) else ""

  paste0(
    '<p class="command"><code>',
    html_escape(name[[2L]]),
    "</code>",
    if (nzchar(args)) paste0(" ", html_escape(args)),
    "</p>"
  )
}

claude_tool_html <- function(block, result, cwd, subagents) {
  input <- block$input

  children <- NULL
  subagent <- subagents[block$id]
  if (!is.na(subagent) && file.exists(subagent)) {
    # The subagent's own prompt is the tool input
    items <- Filter(
      function(item) item$role == "assistant",
      claude_items(read_jsonl(subagent), cwd)
    )
    children <- paste0(
      '<div class="subagent">\n',
      render_turns(items, c(assistant = "Subagent"), dividers = FALSE),
      "\n</div>"
    )
  }

  tool_html(
    summary = claude_tool_summary(block$name, input, cwd),
    input = claude_tool_input(block$name, input),
    output = result$text,
    error = isTRUE(result$error),
    children = children
  )
}

claude_tool_summary <- function(name, input, cwd) {
  switch(
    name,
    Read = ,
    Edit = ,
    Write = paste(name, relative_path(input$file_path, cwd)),
    NotebookEdit = paste(name, relative_path(input$notebook_path, cwd)),
    WebFetch = paste(name, input$url),
    Bash = paste0(name, ": ", first_line(input$command)),
    Agent = ,
    Task = paste0(name, ": ", input$description),
    AskUserQuestion = paste0("Question: ", input$questions[[1L]]$question),
    WebSearch = ,
    ToolSearch = paste0(name, ": ", input$query),
    name
  )
}

claude_tool_input <- function(name, input) {
  switch(
    name,
    Read = NULL,
    Bash = pre_html(input$command),
    Edit = diff_html(c(
      paste0("-", split_lines(input$old_string)),
      paste0("+", split_lines(input$new_string))
    )),
    Write = pre_html(input$content),
    Agent = ,
    Task = markdown(input$prompt),
    AskUserQuestion = questions_html(
      vapply(input$questions, function(q) q$question, character(1)),
      lapply(input$questions, function(q) {
        vapply(q$options, function(option) option$label, character(1))
      })
    ),
    if (length(input)) {
      pre_html(jsonlite::toJSON(input, auto_unbox = TRUE, pretty = TRUE))
    }
  )
}

# ------------------------------------------------------------------------------
# Codex transcripts

codex_items <- function(entries, cwd) {
  outputs <- codex_outputs(entries)

  items <- lapply(entries, function(entry) {
    if (!is_type(entry, "response_item")) {
      return(NULL)
    }
    payload <- entry$payload
    time <- parse_time(entry$timestamp)

    switch(
      payload$type,
      message = {
        text <- codex_text(payload$content)
        if (identical(payload$role, "assistant")) {
          prose_item("assistant", time, text)
        } else if (identical(payload$role, "user") && is_prompt(text)) {
          prose_item("user", time, text)
        }
      },
      reasoning = thinking_item(
        time,
        paste(
          vapply(
            payload$summary,
            function(block) block$text %||% "",
            character(1)
          ),
          collapse = "\n\n"
        )
      ),
      function_call = ,
      custom_tool_call = {
        input <- payload$input %||% payload$arguments
        new_item(
          "assistant",
          time,
          tool_html(
            summary = codex_tool_summary(payload$name, input, cwd),
            input = codex_tool_input(payload$name, input),
            output = outputs[[payload$call_id]]
          )
        )
      }
    )
  })

  compact(items)
}

codex_text <- function(content) {
  paste(
    vapply(content, function(block) block$text %||% "", character(1)),
    collapse = ""
  )
}

# Tool outputs by the id of the call they answer
codex_outputs <- function(entries) {
  outputs <- list()
  for (entry in entries) {
    if (!is_type(entry, "response_item")) {
      next
    }
    payload <- entry$payload

    if (payload$type %in% c("function_call_output", "custom_tool_call_output")) {
      outputs[[payload$call_id]] <- codex_output_text(payload$output)
      next
    }

    if (!identical(payload$type, "message")) {
      next
    }

    # Answers to `request_user_input_async` arrive as a separate user message
    text <- codex_text(payload$content)
    reply <- regmatches(
      text,
      regexec(
        "^<send_user_message_question_reply>(.*)</send_user_message_question_reply>",
        text
      )
    )[[1L]]
    if (length(reply) == 0L) {
      next
    }
    for (answer in jsonlite::parse_json(reply[[2L]])) {
      call_id <- jsonlite::parse_json(answer$questionItemId)[[2L]]
      outputs[[call_id]] <- paste(
        c(outputs[[call_id]], answer$question, paste("→", answer$answer)),
        collapse = "\n"
      )
    }
  }
  outputs
}

codex_output_text <- function(output) {
  if (is.character(output)) {
    return(output)
  }
  texts <- vapply(
    output,
    function(block) unwrap_outputs(block$text %||% ""),
    character(1)
  )
  paste(texts[nzchar(texts)], collapse = "\n")
}

# `exec` results are JSON that wraps each command's output
unwrap_outputs <- function(text) {
  value <- tryCatch(jsonlite::parse_json(text), error = function(e) NULL)
  if (!is.list(value)) {
    return(text)
  }

  outputs <- character()
  walk <- function(x) {
    if (!is.list(x)) {
      return()
    }
    if (is.character(x$output) && length(x$output) == 1L) {
      outputs[[length(outputs) + 1L]] <<- x$output
    }
    lapply(x, walk)
  }
  walk(value)

  if (length(outputs)) paste(outputs, collapse = "\n") else text
}

codex_tool_summary <- function(name, input, cwd) {
  if (name == "request_user_input_async") {
    questions <- jsonlite::parse_json(input)$questions
    return(paste0("Question: ", questions[[1L]]$title))
  }
  if (name != "exec") {
    return(name)
  }

  files <- patch_files(codex_patches(input))
  if (length(files)) {
    return(paste("Edit", with_more(relative_path(files, cwd))))
  }

  commands <- codex_commands(input)
  if (length(commands)) {
    return(paste0("Bash: ", with_more(first_line(commands))))
  }

  tools <- regmatches(input, gregexpr("(?<=tools\\.)\\w+", input, perl = TRUE))
  tools <- unique(tools[[1L]])
  if (length(tools)) {
    labels <- codex_tool_labels[tools]
    return(paste(ifelse(is.na(labels), tools, labels), collapse = ", "))
  }

  first_line(input)
}

codex_tool_input <- function(name, input) {
  if (name == "request_user_input_async") {
    questions <- jsonlite::parse_json(input)$questions
    return(questions_html(
      vapply(questions, function(q) q$title, character(1)),
      lapply(questions, function(q) as.character(unlist(q$options)))
    ))
  }
  if (name != "exec") {
    return(pre_html(input))
  }

  patches <- codex_patches(input)
  if (length(patches)) {
    return(diff_html(split_lines(paste(patches, collapse = "\n"))))
  }

  commands <- codex_commands(input)
  if (length(commands)) {
    return(pre_html(paste0("$ ", commands, collapse = "\n")))
  }

  pre_html(input)
}

codex_patches <- function(code) {
  patches <- regmatches(
    code,
    gregexpr("(?s)\\*\\*\\* Begin Patch.*?\\*\\*\\* End Patch", code, perl = TRUE)
  )[[1L]]

  out <- character()
  for (patch in patches) {
    # Template literals hold real newlines, string literals hold escapes
    template <- grepl("\n", patch, fixed = TRUE)

    # A patch assembled in code spans more than one literal
    if (template && grepl("`", patch, fixed = TRUE)) {
      next
    }
    if (!template && grepl('(?<!\\\\)"', patch, perl = TRUE)) {
      next
    }

    out <- c(out, if (template) patch else decode_js_string(patch))
  }
  out
}

patch_files <- function(patches) {
  files <- regmatches(
    patches,
    gregexpr(
      "(?m)^\\*\\*\\* (?:Update|Add|Delete) File: \\K.+$",
      patches,
      perl = TRUE
    )
  )
  unique(trimws(unlist(files)))
}

# Shell commands from `cmd: "..."` arguments, or a `cmds = [...]` array
codex_commands <- function(code) {
  commands <- js_strings(code, '(?<!\\w)"?cmd"?\\s*:\\s*')
  if (length(commands)) {
    return(commands)
  }
  array <- regmatches(
    code,
    regexec("(?s)(?<!\\w)cmds\\s*=\\s*\\[(.*?)\\]", code, perl = TRUE)
  )[[1L]]
  if (length(array)) js_strings(array[[2L]]) else character()
}

# Double quoted JS strings, each following `prefix`
js_strings <- function(code, prefix = "") {
  pattern <- paste0(prefix, '"((?:[^"\\\\]|\\\\.)*)"')
  matches <- regmatches(code, gregexpr(pattern, code, perl = TRUE))[[1L]]
  vapply(
    sub(pattern, "\\1", matches, perl = TRUE),
    decode_js_string,
    character(1),
    USE.NAMES = FALSE
  )
}

decode_js_string <- function(x) {
  tryCatch(
    jsonlite::parse_json(paste0('"', x, '"')),
    error = function(e) x
  )
}

# ------------------------------------------------------------------------------
# HTML

markdown <- function(text, hardbreaks = FALSE) {
  # commonmark passes raw HTML through, so `<` is shielded from it
  text <- gsub("<", "", text, fixed = TRUE)
  html <- commonmark::markdown_html(
    text,
    hardbreaks = hardbreaks,
    extensions = TRUE
  )
  html <- gsub("", "&lt;", html, fixed = TRUE)

  # Links to local files are dead on the web
  gsub(
    '<a href="(?!https?://)[^"]*">(.*?)</a>',
    "\\1",
    html,
    perl = TRUE
  )
}

pre_html <- function(text, class = NULL) {
  lines <- split_lines(text)
  cut <- length(lines) - transcript_lines
  if (cut > 0L) {
    lines <- lines[seq_len(transcript_lines)]
  }
  paste0(
    "<pre",
    if (!is.null(class)) sprintf(' class="%s"', class),
    ">",
    html_escape(paste(lines, collapse = "\n")),
    "</pre>",
    cut_html(cut)
  )
}

diff_html <- function(lines) {
  cut <- length(lines) - transcript_lines
  if (cut > 0L) {
    lines <- lines[seq_len(transcript_lines)]
  }
  classes <- ifelse(
    startsWith(lines, "+") & !startsWith(lines, "+++"),
    "ins",
    ifelse(
      startsWith(lines, "-") & !startsWith(lines, "---"),
      "del",
      ifelse(startsWith(lines, "@@") | startsWith(lines, "***"), "hunk", "")
    )
  )
  lines <- ifelse(
    nzchar(classes),
    sprintf('<span class="%s">%s</span>', classes, html_escape(lines)),
    html_escape(lines)
  )
  paste0(
    '<pre class="diff">',
    paste(lines, collapse = "\n"),
    "</pre>",
    cut_html(cut)
  )
}

cut_html <- function(cut) {
  if (cut <= 0L) {
    return("")
  }
  sprintf(
    '<p class="cut">%s more line%s cut</p>',
    format(cut, big.mark = ","),
    if (cut == 1L) "" else "s"
  )
}

questions_html <- function(questions, options) {
  markdown(paste(
    vapply(
      seq_along(questions),
      function(i) {
        paste(c(questions[[i]], paste("-", options[[i]])), collapse = "\n")
      },
      character(1)
    ),
    collapse = "\n\n"
  ))
}

inline_html <- function(text) {
  gsub("`([^`]+)`", "<code>\\1</code>", html_escape(text))
}

html_escape <- function(text) {
  text <- gsub("&", "&amp;", text, fixed = TRUE)
  text <- gsub("<", "&lt;", text, fixed = TRUE)
  text <- gsub(">", "&gt;", text, fixed = TRUE)
  gsub('"', "&quot;", text, fixed = TRUE)
}

# Fails rather than masks, so a leaked token is noticed and revoked
redact <- function(page, id) {
  page <- gsub("/Users/davis", "~", page, fixed = TRUE)

  secrets <- regmatches(page, gregexpr(secret_pattern, page, perl = TRUE))
  secrets <- unique(secrets[[1L]])
  if (length(secrets)) {
    cli::cli_abort(c(
      "The transcript of {.field {id}} contains {length(secrets)} token-shaped string{?s}.",
      "i" = "Starting with: {.val {substr(secrets, 1, 10)}}"
    ))
  }

  page
}

# ------------------------------------------------------------------------------
# Utils

git <- function(..., error_on_status = TRUE) {
  result <- processx::run(
    "git",
    c("-C", rray_path, ...),
    error_on_status = error_on_status
  )
  if (result$status != 0L) {
    return(character())
  }
  strsplit(result$stdout, "\n", fixed = TRUE)[[1L]]
}

list_jsonl <- function(dirs, recursive) {
  unlist(lapply(
    dirs,
    list.files,
    pattern = "\\.jsonl$",
    full.names = TRUE,
    recursive = recursive
  ))
}

read_jsonl <- function(path) {
  lines <- readLines(path, warn = FALSE, encoding = "UTF-8")
  lapply(lines[nzchar(lines)], jsonlite::parse_json)
}

# Every input time is UTC with a `Z` suffix
parse_time <- function(x) {
  as.POSIXct(x, format = "%Y-%m-%dT%H:%M:%OS", tz = "UTC")
}

format_time <- function(x) {
  format(x, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
}

format_day <- function(x) {
  paste0(format(x, "%b "), as.integer(format(x, "%d")), format(x, ", %Y"))
}

format_minute <- function(x) {
  paste0(format_day(x), format(x, ", %H:%M UTC"))
}

relative_path <- function(path, cwd) {
  path <- path %||% ""
  if (is.null(cwd)) {
    return(path)
  }
  prefix <- paste0(cwd, "/")
  ifelse(startsWith(path, prefix), substring(path, nchar(prefix) + 1L), path)
}

split_lines <- function(text) {
  text <- paste(text %||% "", collapse = "\n")
  if (!nzchar(text)) {
    return(character())
  }
  strsplit(text, "\n", fixed = TRUE)[[1L]]
}

first_line <- function(text) {
  vapply(
    text,
    function(x) {
      lines <- split_lines(trimws(x))
      if (length(lines)) lines[[1L]] else ""
    },
    character(1),
    USE.NAMES = FALSE
  )
}

with_more <- function(x) {
  if (length(x) > 1L) {
    paste0(x[[1L]], " (+", length(x) - 1L, " more)")
  } else {
    x
  }
}

ellipsize <- function(x, width) {
  if (nchar(x) > width) paste0(substr(x, 1L, width - 1L), "…") else x
}

plural <- function(n, one, many) {
  paste(n, if (n == 1L) one else many)
}

sum_field <- function(entries, fields) {
  sum(vapply(
    entries,
    function(entry) {
      sum(vapply(
        fields,
        function(field) as.numeric(entry[[field]] %||% 0),
        numeric(1)
      ))
    },
    numeric(1)
  ))
}

is_type <- function(entry, type) {
  isTRUE(entry$type %in% type)
}

compact <- function(x) {
  Filter(Negate(is.null), x)
}

main()
