import * as d3 from "https://cdn.jsdelivr.net/npm/d3@7.9.0/+esm";

const MARGIN = { top: 12, right: 12, bottom: 28, left: 36 };

// Unshipped sessions sit in a track between the plot and the x axis
const TRACK = { gap: 6, height: 8 };

const STRIP_HEIGHT = 36;

const RADIUS = { add: 4.5, other: 2.5 };

// Labels with more names than this show a count instead
const MAX_ADDED_NAMES = 3;

// Only the most complex PRs are labeled, fewer on narrow screens
const LABEL_COUNT = { wide: 10, narrow: 5 };
const NARROW_WIDTH = 576;

const MIN_TICK_SPACING = 64;

const DAY = 24 * 60 * 60 * 1000;
const MIN_WINDOW = 2 * DAY;

// How far the pointer can be from a dot and still hover it
const HOVER_RADIUS = 16;

const BAND_MIN_WIDTH = 2;
const REVIEW_TICK = 6;

const HASH = /^#pr-(\d+)$/;

const TOOLS = { claude: "Claude", codex: "Codex" };

const formatDate = d3.timeFormat("%B %-d, %Y");
const formatDay = d3.timeFormat("%b %-d");
const formatTokens = d3.format(".3~s");

let clips = 0;

export async function mount(target, url) {
  const root = d3.select(target).classed("rray-timeline", true);
  // Transcript pages are relative to the JSON, not the page hosting the chart
  const base = new URL(url, document.baseURI);
  const timeline = new Timeline(root, buildModel(await d3.json(url), base));

  new ResizeObserver(([entry]) => {
    timeline.resize(Math.round(entry.contentRect.width));
  }).observe(timeline.figure.node());

  timeline.followHash();
  addEventListener("hashchange", () => timeline.followHash());
}

function buildModel(data, base) {
  const sessions = new Map(
    Object.entries(data.sessions).map(([id, session]) => [
      id,
      {
        id,
        tool: session.tool,
        agent: session.agent,
        title: session.title,
        page: session.page ? new URL(session.page, base).href : null,
        segments: session.segments.map((segment) => segment.map((time) => new Date(time))),
        prompts: session.messages.user,
        prs: session.prs,
      },
    ]),
  );

  const prs = data.prs
    .map((pr) => ({
      number: pr.number,
      date: new Date(pr.merged),
      opened: new Date(pr.opened),
      title: pr.title,
      label: pr.label,
      haystack: [
        `#${pr.number}`,
        pr.title.replaceAll("`", ""),
        pr.label ?? "",
        ...pr.added.map(fn),
        ...pr.renamed.flatMap(({ from, to }) => [fn(from), fn(to)]),
      ]
        .join(" ")
        .toLowerCase(),
      url: pr.url,
      exports: pr.exports,
      added: pr.added,
      renamed: pr.renamed,
      reviews: pr.reviews.map((time) => new Date(time)),
      score: pr.complexity.score,
      parts: pr.complexity.parts,
      context: pr.complexity.context,
      sessions: d3.sort(
        pr.sessions.map((id) => sessions.get(id)),
        (session) => session.segments[0][0],
      ),
    }))
    .sort((a, b) => a.date - b.date);

  for (const pr of prs) {
    pr.kind = pr.added.length ? "add" : "other";
    pr.label = pr.label ?? exportLabel(pr);
  }

  // PRs without a short label only show on hover
  const ranked = d3.sort(
    prs.filter((pr) => pr.score !== null && pr.label !== null),
    (pr) => -pr.score,
  );

  const unshipped = [...sessions.values()].filter((session) => !session.prs.length);

  const start = d3.timeDay.floor(prs[0].date);
  const end = new Date(data.generated);

  // Exports from before the first PR are carried in from the start
  const steps = [
    { date: start, exports: prs[0].exports },
    ...prs,
    { date: end, exports: prs.at(-1).exports },
  ];

  const byNumber = new Map(prs.map((pr) => [pr.number, pr]));

  return { start, end, prs, byNumber, ranked, unshipped, steps };
}

class Timeline {
  constructor(root, model) {
    this.root = root;
    this.model = model;
    this.extent = [model.start, model.end];
    this.domain = this.extent;

    this.selected = null;
    this.hovered = null;
    this.highlighted = null;

    // PRs matching the search, or `null` without one
    this.matches = null;

    // Unshipped session whose tooltip stays open until dismissed
    this.pinned = null;

    // The one dot in the tab order
    this.active = model.prs[0];

    this.width = 0;
    this.scrollPending = false;

    root.append("div").attr("class", "tl-title").text("Number of exported functions over time");
    const legend = root.append("div").attr("class", "tl-legend");
    renderLegend(legend);
    this.renderSearch(legend);
    this.figure = root.append("div").attr("class", "tl-figure");
    this.tooltip = root.append("div").attr("class", "tl-tooltip").attr("aria-hidden", true).attr("hidden", "");
    this.panel = root.append("div").attr("class", "tl-panel").attr("aria-live", "polite");

    root.on("keydown", (event) => {
      if (event.key !== "Escape") return;
      this.hover(null);
      if (this.pinned) {
        event.preventDefault();
        this.pin(null);
      } else if (this.selected) {
        event.preventDefault();
        this.select(null);
      }
    });

    addEventListener("click", (event) => {
      if (!this.pinned) return;
      if (this.tooltip.node().contains(event.target) || event.target.closest(".tl-track a")) return;
      this.pin(null);
    });

    this.renderPanel();
  }

  renderSearch(parent) {
    const search = parent.append("span").attr("class", "tl-search");

    this.count = search.append("span").attr("class", "tl-search-count").attr("aria-live", "polite");

    const field = search.append("span").attr("class", "tl-search-field");

    this.input = field
      .append("input")
      .attr("type", "search")
      .attr("placeholder", "Filter PRs")
      .attr("aria-label", "Filter pull requests")
      .attr("spellcheck", false)
      .on("input", () => this.search(this.input.property("value")))
      .on("keydown", (event) => {
        if (event.key !== "Escape" || !this.input.property("value")) return;
        event.preventDefault();
        event.stopPropagation();
        this.clearSearch();
      });

    this.clear = field
      .append("button")
      .attr("type", "button")
      .attr("class", "tl-close")
      .attr("aria-label", "Clear filter")
      .attr("hidden", "")
      .text("×")
      .on("click", () => {
        this.clearSearch();
        this.input.node().focus();
      });
  }

  search(query) {
    this.filter(query);
    this.hover(null);
    this.raiseMatches();

    if (this.selected && !this.matching(this.selected)) this.select(null);
    else this.update();
  }

  clearSearch() {
    this.input.property("value", "");
    this.search("");
  }

  // Every word must appear, in any order
  filter(query) {
    const terms = query.toLowerCase().split(/\s+/).filter(Boolean);

    this.matches = terms.length
      ? new Set(this.model.prs.filter((pr) => terms.every((term) => pr.haystack.includes(term))))
      : null;

    this.clear.attr("hidden", this.matches ? null : "");
    this.count.text(this.matches ? plural(this.matches.size, "PR") : "");

    if (this.matches?.size && !this.matches.has(this.active)) {
      this.active = d3.least(this.matches, (pr) => Math.abs(pr.date - this.active.date));
    }
  }

  matching(pr) {
    return !this.matches || this.matches.has(pr);
  }

  resize(width) {
    // Zero while the page is hidden or tearing down
    if (!width || width === this.width) return;

    const focused = this.figure.node().contains(document.activeElement);

    this.width = width;
    this.height = Math.round(Math.max(320, Math.min(520, width * 0.6)));
    this.plot = {
      x0: MARGIN.left,
      x1: width - MARGIN.right,
      y0: MARGIN.top,
      y1: this.height - MARGIN.bottom - TRACK.gap - TRACK.height,
    };

    this.hover(null);
    this.figure.selectAll("*").remove();
    this.buildMain();
    this.buildStrip();
    this.update();

    if (focused) this.nodes.get(this.active).focus({ preventScroll: true });

    if (this.scrollPending) {
      this.scrollPending = false;
      this.scrollIntoView();
    }
  }

  buildMain() {
    const { model, plot, width, height } = this;

    const svg = this.figure
      .append("svg")
      .attr("class", "tl-main")
      .attr("width", width)
      .attr("height", height)
      .attr("viewBox", [0, 0, width, height])
      .attr("role", "group")
      .attr("aria-label", "Exported functions in rray over time, one dot per merged pull request");

    const clip = `tl-clip-${++clips}`;
    svg
      .append("clipPath")
      .attr("id", clip)
      .append("rect")
      .attr("x", plot.x0)
      .attr("width", plot.x1 - plot.x0)
      .attr("height", height - MARGIN.bottom);

    this.yAxis = svg
      .append("g")
      .attr("class", "tl-axis tl-axis-y")
      .attr("transform", `translate(${plot.x0},0)`);

    this.xAxis = svg
      .append("g")
      .attr("class", "tl-axis tl-axis-x")
      .attr("transform", `translate(0,${height - MARGIN.bottom})`);

    const body = svg.append("g").attr("clip-path", `url(#${clip})`);

    this.bands = selectionLayers(body);

    this.line = body.append("path").attr("class", "tl-line");

    this.track = body
      .append("g")
      .attr("class", "tl-track")
      .selectAll("a")
      .data(model.unshipped)
      .join("a")
      .attr("href", (session) => session.page)
      .attr("aria-label", (session) => `${session.title}, ${dayRange(session)}, didn't ship`)
      .on("pointerenter", (event, session) => this.showSessionTooltip(session))
      .on("pointerleave", () => this.hideTooltip())
      .on("click", (event, session) => {
        // Modified clicks still open the transcript
        if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
        event.preventDefault();
        this.pin(session === this.pinned ? null : session);
      });

    this.track
      .selectAll("rect")
      .data((session) => session.segments)
      .join("rect");

    // Small dots first so larger ones draw on top
    this.dots = body
      .append("g")
      .selectAll("g")
      .data(d3.sort(model.prs, (pr) => pr.kind !== "other"))
      .join("g")
      .attr("class", (pr) => `tl-dot tl-dot-${pr.kind}`)
      .attr("role", "button")
      .attr("aria-label", (pr) => describe(pr).join(", "))
      .on("keydown", (event, pr) => this.keydown(event, pr))
      .on("focus", (event, pr) => this.focused(event, pr))
      .on("blur", () => this.hideTooltip());

    this.dots
      .append("circle")
      .attr("r", (pr) => RADIUS[pr.kind])
      .style("fill", fill);

    const nodes = (this.nodes = new Map());
    this.dots.each(function (pr) {
      nodes.set(pr, this);
    });
    this.raiseMatches();

    // Pointer input goes through the nearest dot rather than each dot's tiny hit area
    this.overlay = svg
      .append("rect")
      .attr("class", "tl-overlay")
      .attr("x", plot.x0)
      .attr("width", plot.x1 - plot.x0)
      .attr("height", plot.y1)
      .on("pointermove", (event) => {
        if (event.pointerType === "mouse") this.hover(this.nearest(event));
      })
      .on("pointerleave", () => this.hover(null))
      .on("click", (event) => {
        const pr = this.nearest(event);
        this.select(pr === this.selected ? null : pr);
      });

    // Above the overlay so labels can be clicked
    this.labels = svg.append("g").attr("class", "tl-labels");

    this.svg = svg;
  }

  buildStrip() {
    const { model, plot, width } = this;

    const svg = this.figure
      .append("svg")
      .attr("class", "tl-strip")
      .attr("width", width)
      .attr("height", STRIP_HEIGHT)
      .attr("aria-label", "Overview of the full timeline, drag across it to zoom");

    const x = (this.sx = d3.scaleTime().domain(this.extent).range([plot.x0, plot.x1]));

    const y = d3
      .scaleLinear()
      .domain([0, model.steps.at(-1).exports])
      .range([STRIP_HEIGHT - 1, 4]);

    this.stripBands = selectionLayers(svg);

    svg
      .append("path")
      .attr("class", "tl-strip-area")
      .attr(
        "d",
        d3
          .area()
          .curve(d3.curveStepAfter)
          .x((step) => x(step.date))
          .y0(y(0))
          .y1((step) => y(step.exports))(model.steps),
      );

    this.stripMatches = svg.append("g").attr("class", "tl-strip-matches");

    this.brush = d3
      .brushX()
      .extent([
        [plot.x0, 0],
        [plot.x1, STRIP_HEIGHT],
      ])
      .on("brush end", (event) => this.brushed(event));

    this.brushLayer = svg.append("g").attr("class", "tl-brush").call(this.brush);
    this.moveBrush();
  }

  brushed({ selection, sourceEvent, type }) {
    // Ignores moves made by `moveBrush()`
    if (!sourceEvent) return;

    this.hover(null);

    if (!selection) {
      this.domain = this.extent;
    } else {
      this.domain = clampDomain(selection.map(this.sx.invert), this.extent);
      if (type === "end") this.moveBrush();
    }

    this.update();
  }

  moveBrush() {
    if (!this.brushLayer) return;
    const full = this.domain[0] <= this.extent[0] && this.domain[1] >= this.extent[1];
    this.brushLayer.call(this.brush.move, full ? null : this.domain.map(this.sx));
  }

  update() {
    if (!this.width) return;

    const { model, plot, domain, selected } = this;

    const x = d3.scaleTime().domain(domain).range([plot.x0, plot.x1]);
    const y = yScale(model.steps, domain).range([plot.y1, plot.y0]);

    this.yAxis
      .call(
        d3
          .axisLeft(y)
          .tickValues(y.ticks((plot.y1 - plot.y0) / 50).filter(Number.isInteger))
          .tickFormat(d3.format("d"))
          .tickSize(-(plot.x1 - plot.x0))
          .tickPadding(6),
      )
      .call((g) => g.select(".domain").remove());

    this.xAxis.call(
      d3.axisBottom(x).ticks(tickInterval(x)).tickFormat(d3.timeFormat("%b %-d")).tickSizeOuter(0),
    );

    const line = d3
      .line()
      .curve(d3.curveStepAfter)
      .x((step) => x(step.date))
      .y((step) => y(step.exports));

    this.line.attr("d", line(model.steps));

    this.track
      .selectAll("rect")
      .call(spanX, x, (segment) => segment)
      .attr("y", plot.y1 + TRACK.gap)
      .attr("height", TRACK.height);

    this.dots
      .attr("transform", (pr) => `translate(${x(pr.date)},${y(pr.exports)})`)
      .attr("tabindex", (pr) => (pr === this.active ? 0 : -1))
      .attr("aria-pressed", (pr) => pr === selected)
      .classed("tl-selected", (pr) => pr === selected)
      .classed("tl-faded", (pr) => (selected && pr !== selected) || !this.matching(pr));

    this.stripMatches
      .selectAll("line")
      .data(this.matches ?? [])
      .join("line")
      .attr("x1", (pr) => this.sx(pr.date))
      .attr("x2", (pr) => this.sx(pr.date))
      .attr("y1", 0)
      .attr("y2", STRIP_HEIGHT);

    this.drawSelection(this.bands, x, plot.y0, plot.y1, { reviews: true });
    this.drawSelection(this.stripBands, this.sx, 0, STRIP_HEIGHT, { reviews: false });

    const inDomain = (pr) => pr.date >= domain[0] && pr.date <= domain[1];
    const shown = model.prs.filter(inDomain);
    const visible = shown.filter((pr) => this.matching(pr));
    const labeled = model.ranked
      .filter((pr) => inDomain(pr) && this.matching(pr))
      .slice(0, this.width < NARROW_WIDTH ? LABEL_COUNT.narrow : LABEL_COUNT.wide);

    this.labels.selectAll("*").remove();
    placeLabels(this.labels, labeled, shown, {
      x,
      y,
      steps: model.steps,
      bounds: { x0: plot.x0, y0: 0, x1: plot.x1, y1: plot.y1 },
    });
    this.labels
      .selectAll(":scope > *")
      .classed("tl-faded", (pr) => selected && pr !== selected);
    this.labels.selectAll("a").on("click", (event, pr) => {
      event.preventDefault();
      this.select(pr);
    });

    this.x = x;
    this.y = y;
    this.visible = visible;
    this.delaunay = d3.Delaunay.from(
      visible,
      (pr) => x(pr.date),
      (pr) => y(pr.exports),
    );

    if (this.pinned) {
      const [start, end] = sessionExtent(this.pinned);
      if (end < domain[0] || start > domain[1]) this.pin(null);
      else if (!this.hovered) this.showSessionTooltip(this.pinned);
    }
  }

  // Bands for the selected PR's conversations, and its open to merge window
  drawSelection(layers, x, y0, y1, { reviews }) {
    const pr = this.selected;

    const segments = pr
      ? pr.sessions.flatMap((session) => session.segments.map(([start, end]) => ({ session, start, end })))
      : [];

    layers.sessions
      .selectAll("rect")
      .data(segments)
      .join("rect")
      .attr("class", "tl-band")
      .call(spanX, x, (segment) => [segment.start, segment.end])
      .attr("y", y0)
      .attr("height", y1 - y0);

    layers.window
      .selectAll("rect")
      .data(pr ? [pr] : [])
      .join("rect")
      .attr("class", "tl-window")
      .call(spanX, x, (pr) => [pr.opened, pr.date])
      .attr("y", y0)
      .attr("height", y1 - y0);

    layers.window
      .selectAll("line")
      .data(pr && reviews ? pr.reviews : [])
      .join("line")
      .attr("class", "tl-review")
      .attr("x1", x)
      .attr("x2", x)
      .attr("y1", y0)
      .attr("y2", y0 + REVIEW_TICK);

    this.highlight(this.highlighted);
  }

  highlight(session) {
    this.highlighted = session;
    for (const layers of [this.bands, this.stripBands]) {
      layers?.sessions
        .selectAll("rect")
        .classed("tl-muted", (segment) => session && segment.session !== session);
    }
  }

  nearest(event) {
    if (!this.visible.length) return null;

    const [px, py] = d3.pointer(event, this.svg.node());
    const pr = this.visible[this.delaunay.find(px, py)];
    const distance = Math.hypot(this.x(pr.date) - px, this.y(pr.exports) - py);

    return distance <= HOVER_RADIUS ? pr : null;
  }

  hover(pr) {
    if (pr === this.hovered) return;
    this.hovered = pr;

    this.dots?.classed("tl-hover", (other) => other === pr);
    this.overlay?.classed("tl-pointing", pr !== null);

    if (pr) this.showPRTooltip(pr);
    else this.hideTooltip();
  }

  pin(session) {
    this.pinned = session;
    if (session) this.showSessionTooltip(session);
    else this.hideTooltip();
  }

  select(pr, { fit = false } = {}) {
    if (this.pinned) this.pin(null);
    this.selected = pr;
    this.highlighted = null;

    // A deep link to a PR the search hides
    if (pr && !this.matching(pr)) {
      this.input.property("value", "");
      this.filter("");
      this.raiseMatches();
    }

    if (pr) {
      this.active = pr;
      this.raise(pr);
    }

    if (pr && fit) {
      this.domain = fitDomain(pr, this.extent);
      this.moveBrush();
    }

    writeHash(pr);
    this.renderPanel();
    this.update();
  }

  // Faded dots would otherwise draw over smaller matches
  raiseMatches() {
    if (!this.dots) return;
    this.dots.order();
    if (this.matches) this.dots.filter((pr) => this.matches.has(pr)).raise();
    this.raise(this.selected);
  }

  // Moving the node blurs it, so focus is put back
  raise(pr) {
    const node = this.nodes?.get(pr);
    if (!node) return;

    const focused = document.activeElement === node;
    d3.select(node).raise();
    if (focused) node.focus({ preventScroll: true });
  }

  followHash() {
    const match = HASH.exec(location.hash);
    const pr = match && this.model.byNumber.get(Number(match[1]));
    if (!pr) return;

    this.select(pr, { fit: true });

    // The hash names no element, so the browser won't scroll to the chart
    if (this.width) this.scrollIntoView();
    else this.scrollPending = true;
  }

  scrollIntoView() {
    this.root.node().scrollIntoView({ block: "center" });
  }

  keydown(event, pr) {
    const prs = this.model.prs.filter((other) => this.matching(other));
    const i = prs.indexOf(pr);

    const target = {
      ArrowLeft: i - 1,
      ArrowUp: i - 1,
      ArrowRight: i + 1,
      ArrowDown: i + 1,
      Home: 0,
      End: prs.length - 1,
    }[event.key];

    if (target !== undefined) {
      event.preventDefault();
      const next = prs[Math.max(0, Math.min(target, prs.length - 1))];
      if (next) this.nodes.get(next).focus({ preventScroll: true });
      return;
    }

    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      this.select(pr === this.selected ? null : pr);
    }
  }

  focused(event, pr) {
    this.active = pr;

    if (pr.date < this.domain[0] || pr.date > this.domain[1]) {
      this.domain = panTo(pr.date, this.domain, this.extent);
      this.moveBrush();
    }

    this.update();

    if (event.currentTarget.matches(":focus-visible")) this.showPRTooltip(pr);
  }

  showPRTooltip(pr) {
    const point = [this.x(pr.date), this.y(pr.exports) - RADIUS[pr.kind]];

    this.showTooltip(this.svg.node(), point, (tooltip) => {
      const [title, ...rest] = describe(pr);
      tooltip.append("div").attr("class", "tl-tooltip-title").call(inline, title);
      for (const line of rest) tooltip.append("div").text(line);
    });
  }

  showSessionTooltip(session) {
    const { plot } = this;
    const [start, end] = sessionExtent(session);
    const middle = this.x(new Date((+start + +end) / 2));
    const point = [Math.max(plot.x0, Math.min(middle, plot.x1)), plot.y1 + TRACK.gap];
    const pinned = session === this.pinned;

    const content = (tooltip) => {
      tooltip.append("div").attr("class", "tl-tooltip-title").call(inline, session.title);
      tooltip.append("div").text(`${TOOLS[session.tool]}, ${dayRange(session)}`);
      tooltip.append("div").attr("class", "tl-muted").text("Didn't lead to a merged PR");
      if (pinned && session.page) {
        tooltip.append("a").attr("class", "tl-tooltip-link").attr("href", session.page).text("Open transcript");
      }
    };

    this.showTooltip(this.svg.node(), point, content, { pinned });
  }

  // Places the tooltip above `point`, given in the coordinates of `node`
  showTooltip(node, [px, py], content, { pinned = false } = {}) {
    const tooltip = this.tooltip;
    tooltip.selectAll("*").remove();
    content(tooltip);
    tooltip.attr("hidden", null).attr("aria-hidden", pinned ? null : true).classed("tl-pinned", pinned);

    const origin = this.root.node().getBoundingClientRect();
    const box = node.getBoundingClientRect();
    const { offsetWidth: w, offsetHeight: h } = tooltip.node();

    const left = px + box.left - origin.left - w / 2;
    const top = py + box.top - origin.top - h - 8;

    tooltip
      .style("left", `${Math.max(0, Math.min(left, origin.width - w))}px`)
      .style("top", `${top}px`);
  }

  hideTooltip() {
    if (this.pinned) this.showSessionTooltip(this.pinned);
    else this.tooltip.attr("hidden", "");
  }

  renderPanel() {
    const panel = this.panel;
    const pr = this.selected;

    panel.selectAll("*").remove();

    if (!pr) {
      panel
        .append("p")
        .attr("class", "tl-hint")
        .text("Select a dot to see the conversations behind that pull request.");
      return;
    }

    const header = panel.append("div").attr("class", "tl-panel-header");

    const title = header.append("div").attr("class", "tl-panel-title");
    title.append("a").attr("href", pr.url).text(`#${pr.number}`);
    title.append("span").call(inline, ` ${pr.title}`);

    header
      .append("button")
      .attr("type", "button")
      .attr("class", "tl-close")
      .attr("aria-label", "Clear selection")
      .text("×")
      .on("click", () => {
        this.select(null);
        this.nodes.get(this.active).focus({ preventScroll: true });
      });

    const facts = [`Merged ${formatDate(pr.date)}`, `open for ${duration(pr.date - pr.opened)}`];
    if (pr.reviews.length) facts.push(plural(pr.reviews.length, "review"));
    panel.append("p").attr("class", "tl-facts").text(facts.join(" · "));

    if (pr.added.length || pr.renamed.length) {
      const changes = panel.append("p").attr("class", "tl-changes");
      for (const name of pr.added) changes.append("code").text(`+ ${fn(name)}`);
      for (const { from, to } of pr.renamed) changes.append("code").text(`${fn(from)} → ${fn(to)}`);
    }

    const complexity = panel.append("p");

    if (pr.score === null) {
      complexity.text("Complexity unknown, the transcripts were lost");
    } else {
      complexity.text(
        [
          `Complexity ${pr.score.toFixed(2)}`,
          plural(pr.parts.review_comments, "review thread"),
          plural(pr.parts.messages, "prompt"),
          `${formatTokens(pr.context.tokens)} tokens`,
        ].join(" · "),
      );
    }

    if (!pr.sessions.length) return;

    const items = panel
      .append("ul")
      .attr("class", "tl-sessions")
      .selectAll("li")
      .data(pr.sessions)
      .join("li")
      .on("pointerenter", (event, session) => this.highlight(session))
      .on("pointerleave", () => this.highlight(null));

    items.each(function (session) {
      d3.select(this)
        .append(session.page ? "a" : "span")
        .attr("class", "tl-session-title")
        .attr("href", session.page)
        .call(inline, session.title);
    });

    items
      .append("span")
      .attr("class", "tl-session-meta")
      .text((session) => {
        const active = d3.sum(session.segments, ([start, end]) => end - start);
        const facts = [
          session.agent ? `${TOOLS[session.tool]} review` : TOOLS[session.tool],
          dayRange(session),
          duration(active),
        ];
        if (!session.agent) facts.push(plural(session.prompts, "prompt"));
        return facts.join(" · ");
      });
  }
}

function selectionLayers(parent) {
  const sessions = parent.append("g");
  const window = parent.append("g");
  return { sessions, window };
}

// Sets `x` and `width` from a time extent, widening short spans so they stay visible
function spanX(rects, x, extent) {
  rects.each(function (d) {
    const [x0, x1] = extent(d).map(x);
    const width = Math.max(BAND_MIN_WIDTH, x1 - x0);
    d3.select(this)
      .attr("x", (x0 + x1 - width) / 2)
      .attr("width", width);
  });
}

function exportsAt(steps, date) {
  const i = d3.bisector((step) => step.date).right(steps, date) - 1;
  return steps[Math.max(i, 0)].exports;
}

// The line only rises, so the window's exports run from its left edge to its right edge
function yScale(steps, [start, end]) {
  const lo = exportsAt(steps, start);
  const hi = exportsAt(steps, end);
  const pad = Math.max(1, (hi - lo) * 0.08);
  return d3.scaleLinear().domain([Math.max(0, lo - pad), hi + pad]);
}

function clampDomain([start, end], [lo, hi]) {
  const span = Math.min(Math.max(end - start, MIN_WINDOW), hi - lo);
  const mid = (+start + +end) / 2;
  const from = Math.min(Math.max(mid - span / 2, +lo), hi - span);
  return [new Date(from), new Date(from + span)];
}

function fitDomain(pr, extent) {
  const times = [pr.opened, pr.date, ...pr.sessions.flatMap((session) => session.segments.flat())];
  const [start, end] = d3.extent(times);
  const pad = (end - start) * 0.1;
  return clampDomain([start - pad, +end + pad], extent);
}

function panTo(date, [start, end], extent) {
  const span = end - start;
  const margin = span * 0.1;
  const from = date < start ? date - margin : date - span + margin;
  return clampDomain([from, from + span], extent);
}

function writeHash(pr) {
  // Leaves hashes that aren't ours alone
  if (!pr && !HASH.test(location.hash)) return;

  const url = new URL(location.href);
  url.hash = pr ? `pr-${pr.number}` : "";
  history.replaceState(history.state, "", url);
}

function exportLabel(pr) {
  const { added } = pr;

  if (added.length > MAX_ADDED_NAMES) return `${added.length} new exports`;
  if (added.length) return added.map(fn).join(", ");

  return null;
}

function fn(name) {
  return `${name}()`;
}

function describe(pr) {
  const lines = [`#${pr.number} ${pr.title}`, formatDate(pr.date)];
  for (const name of pr.added) lines.push(`+ ${fn(name)}`);
  for (const { from, to } of pr.renamed) lines.push(`${fn(from)} → ${fn(to)}`);
  return lines;
}

// Appends `text` with its backtick spans as `<code>`
function inline(selection, text) {
  text.split("`").forEach((part, i) => {
    if (part) selection.append(i % 2 ? "code" : "span").text(part);
  });
}

function sessionExtent(session) {
  return [session.segments[0][0], session.segments.at(-1)[1]];
}

function dayRange(session) {
  const [start, end] = sessionExtent(session);

  if (d3.timeDay.floor(start) - d3.timeDay.floor(end) === 0) return formatDay(start);
  if (start.getMonth() === end.getMonth()) return `${formatDay(start)} – ${end.getDate()}`;
  return `${formatDay(start)} – ${formatDay(end)}`;
}

function duration(ms) {
  const minutes = Math.round(ms / 60000);
  if (minutes < 1) return "<1m";
  if (minutes < 60) return `${minutes}m`;

  const hours = Math.floor(minutes / 60);
  if (hours < 24) return minutes % 60 ? `${hours}h ${minutes % 60}m` : `${hours}h`;

  const days = Math.floor(hours / 24);
  return hours % 24 ? `${days}d ${hours % 24}h` : `${days}d`;
}

function plural(n, word) {
  return `${n} ${word}${n === 1 ? "" : "s"}`;
}

function fill(pr) {
  if (pr.score === null) return "var(--tl-unknown)";
  const percent = Math.round(pr.score * 100);
  return `color-mix(in oklab, var(--tl-complex) ${percent}%, var(--tl-simple))`;
}

function tickInterval(x) {
  const [start] = x.domain();
  const day = x(d3.timeDay.offset(start, 1)) - x(start);

  if (day >= MIN_TICK_SPACING) return d3.timeDay;
  if (day * 7 >= MIN_TICK_SPACING) return d3.timeWeek;
  if (day * 14 >= MIN_TICK_SPACING) return d3.timeWeek.every(2);
  return d3.timeMonth;
}

// Greedy placement, most complex first. Labels that can't be placed are dropped.
function placeLabels(layer, labeled, prs, { x, y, steps, bounds }) {
  // The step line only rises, so over a box it spans from its height at the left edge up to its height at the right edge
  const hitsLine = (box) => {
    const bottom = y(exportsAt(steps, x.invert(box.x0)));
    const top = y(exportsAt(steps, x.invert(box.x1)));
    return box.y0 <= bottom + 1 && box.y1 >= top - 1;
  };

  const dots = new Map(
    prs.map((pr) => {
      const r = RADIUS[pr.kind] + 1;
      const cx = x(pr.date);
      const cy = y(pr.exports);
      return [pr, { x0: cx - r, y0: cy - r, x1: cx + r, y1: cy + r }];
    }),
  );

  const boxes = [];
  const leaders = [];

  const fits = (pr, box) => {
    if (box.x0 < bounds.x0 || box.x1 > bounds.x1 || box.y0 < bounds.y0 || box.y1 > bounds.y1) {
      return false;
    }
    if (hitsLine(box)) return false;
    if (boxes.some((other) => overlaps(box, other))) return false;
    if (leaders.some((leader) => crosses(leader, box))) return false;

    // Dots touching this one can't be avoided where the leader starts
    const own = dots.get(pr);
    for (const dot of dots.values()) {
      if (overlaps(box, dot)) return false;
      if (!overlaps(own, dot) && crosses(box.leader, dot)) return false;
    }

    return !boxes.some((other) => crosses(box.leader, other));
  };

  for (const pr of labeled) {
    const link = layer.append("a").datum(pr).attr("href", `#pr-${pr.number}`);
    const text = link.append("text").attr("class", "tl-label").text(pr.label);
    const bbox = text.node().getBBox();

    const cx = x(pr.date);
    const cy = y(pr.exports);
    const r = RADIUS[pr.kind];

    const box = candidates(cx, cy, r, bbox.width, bbox.height).find((box) => fits(pr, box));

    if (!box) {
      link.remove();
      continue;
    }

    boxes.push(box);
    text.attr("x", box.x0 - bbox.x).attr("y", box.y0 - bbox.y);

    leaders.push(box.leader);
    const [[x1, y1], [x2, y2]] = box.leader;
    layer
      .insert("line", ":scope > a")
      .datum(pr)
      .attr("class", "tl-leader")
      .attr("x1", x1)
      .attr("y1", y1)
      .attr("x2", x2)
      .attr("y2", y2);
  }
}

// Only above left and below right are stacked, since those stay clear of the rising line at any distance
function* candidates(cx, cy, r, w, h) {
  // Room for a visible leader, and clears the largest dot on the same row
  const gap = 5;
  const rise = RADIUS.add + 6;

  const box = (x0, y0, anchor) => {
    const x1 = x0 + w;
    const y1 = y0 + h;

    // Leaders run from the edge of the dot to the nearest corner of the label
    const corner = [anchor[0] < 0 ? x0 : x1, anchor[1] < 0 ? y0 : y1];
    const distance = Math.hypot(corner[0] - cx, corner[1] - cy);
    const start = [cx + ((corner[0] - cx) / distance) * r, cy + ((corner[1] - cy) / distance) * r];

    return { x0, y0, x1, y1, leader: [start, corner] };
  };

  yield box(cx - r - gap - w, cy - rise - h, [1, 1]);
  yield box(cx + r + gap, cy + rise, [-1, -1]);
  yield box(cx + r + gap, cy - rise - h, [-1, 1]);
  yield box(cx - r - gap - w, cy + rise, [1, -1]);

  for (let level = 1; level <= 3; level++) {
    const shift = level * (h + 2);
    yield box(cx - r - gap - w, cy - rise - h - shift, [1, 1]);
    yield box(cx + r + gap, cy + rise + shift, [-1, -1]);
  }
}

function overlaps(a, b) {
  return a.x0 < b.x1 && b.x0 < a.x1 && a.y0 < b.y1 && b.y0 < a.y1;
}

// Liang-Barsky clipping of a segment against a box
function crosses([[x1, y1], [x2, y2]], box) {
  const dx = x2 - x1;
  const dy = y2 - y1;

  let t0 = 0;
  let t1 = 1;

  for (const [p, q] of [
    [-dx, x1 - box.x0],
    [dx, box.x1 - x1],
    [-dy, y1 - box.y0],
    [dy, box.y1 - y1],
  ]) {
    if (p === 0) {
      if (q < 0) return false;
      continue;
    }

    const t = q / p;
    if (p < 0) t0 = Math.max(t0, t);
    else t1 = Math.min(t1, t);
    if (t0 > t1) return false;
  }

  return true;
}

function renderLegend(legend) {
  const key = (text, draw) => {
    const item = legend.append("span").attr("class", "tl-key");
    draw(item);
    item.append("span").text(text);
  };

  const swatch = (item, kind) => {
    const svg = item.append("svg").attr("width", 14).attr("height", 14).attr("viewBox", "-7 -7 14 14");
    return svg.append("circle").attr("class", "tl-key-dot").attr("r", RADIUS[kind]);
  };

  key("New function", (item) => swatch(item, "add"));
  key("Other", (item) => swatch(item, "other"));
  key("Lost transcript", (item) => swatch(item, "other").style("fill", "var(--tl-unknown)"));

  const ramp = legend.append("span").attr("class", "tl-key");
  ramp.append("span").text("Simple");
  ramp.append("span").attr("class", "tl-ramp");
  ramp.append("span").text("Complex");
}
