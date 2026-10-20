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

main <- function() {
  overrides <- yaml::read_yaml("overrides.yml")

  commits <- read_commits(overrides$renames)
  prs <- read_prs()
  sessions <- read_sessions()

  dropped <- names(Filter(is.null, overrides$sessions))
  sessions <- sessions[!names(sessions) %in% dropped]

  links <- link_sessions(sessions, prs, compact(overrides$sessions))
  report_unmatched(sessions, links)

  timeline <- build_timeline(commits, prs, sessions, links, overrides$labels)

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
    "{length(timeline$sessions)} sessions"
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
  entries <- read_jsonl(path)
  entries <- Filter(function(entry) !isTRUE(entry$isSidechain), entries)

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
    uuid = sub("\\.jsonl$", "", basename(path)),
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
  lines <- strsplit(trimws(prompts[[1L]]), "\n", fixed = TRUE)[[1L]]
  title <- trimws(lines[[1L]])
  if (nchar(title) > 80L) {
    title <- paste0(substr(title, 1L, 79L), "…")
  }
  title
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

    linked <- intersect(session$pr_links, numbers)
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
