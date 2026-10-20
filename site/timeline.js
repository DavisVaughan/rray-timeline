import * as d3 from "https://cdn.jsdelivr.net/npm/d3@7.9.0/+esm";

const MARGIN = { top: 12, right: 12, bottom: 28, left: 36 };

const RADIUS = { add: 4.5, other: 2.5 };

// Labels with more names than this show a count instead
const MAX_ADDED_NAMES = 3;

// Only the most complex PRs are labeled, fewer on narrow screens
const LABEL_COUNT = { wide: 10, narrow: 5 };
const NARROW_WIDTH = 576;

const MIN_TICK_SPACING = 64;

export async function mount(target, url) {
  const root = d3.select(target).classed("rray-timeline", true);
  const model = buildModel(await d3.json(url));

  renderLegend(root.append("div").attr("class", "tl-legend"));
  const figure = root.append("div").attr("class", "tl-figure");

  let width = 0;
  new ResizeObserver(([entry]) => {
    const next = Math.round(entry.contentRect.width);
    if (next === width) return;
    width = next;
    render(figure, model, width);
  }).observe(figure.node());
}

function buildModel(data) {
  const prs = data.prs
    .map((pr) => ({
      number: pr.number,
      date: new Date(pr.merged),
      title: pr.title,
      label: pr.label,
      url: pr.url,
      exports: pr.exports,
      added: pr.added,
      renamed: pr.renamed,
      score: pr.complexity.score,
    }))
    .sort((a, b) => a.date - b.date);

  for (const pr of prs) {
    pr.kind = pr.added.length ? "add" : "other";
    pr.label = pr.label ?? exportLabel(pr) ?? pr.title;
  }

  const ranked = d3.sort(
    prs.filter((pr) => pr.score !== null),
    (pr) => -pr.score,
  );

  const start = d3.timeDay.floor(prs[0].date);
  const end = new Date(data.generated);

  // Exports from before the first PR are carried in from the start
  const steps = [
    { date: start, exports: prs[0].exports },
    ...prs,
    { date: end, exports: prs.at(-1).exports },
  ];

  return { start, end, prs, ranked, steps };
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
  const lines = [`#${pr.number} ${pr.title}`, d3.timeFormat("%B %-d, %Y")(pr.date)];
  for (const name of pr.added) lines.push(`+ ${fn(name)}`);
  for (const { from, to } of pr.renamed) lines.push(`${fn(from)} → ${fn(to)}`);
  return lines.join("\n");
}

function fill(pr) {
  if (pr.score === null) return "var(--tl-unknown)";
  const percent = Math.round(pr.score * 100);
  return `color-mix(in oklab, var(--tl-complex) ${percent}%, var(--tl-simple))`;
}

function render(figure, model, width) {
  const height = Math.round(Math.max(320, Math.min(520, width * 0.6)));

  const x = d3
    .scaleTime()
    .domain([model.start, model.end])
    .range([MARGIN.left, width - MARGIN.right]);

  const y = d3
    .scaleLinear()
    .domain([0, d3.max(model.steps, (step) => step.exports)])
    .nice()
    .range([height - MARGIN.bottom, MARGIN.top]);

  figure.selectAll("*").remove();

  const svg = figure
    .append("svg")
    .attr("width", width)
    .attr("height", height)
    .attr("viewBox", [0, 0, width, height])
    .attr("role", "img")
    .attr("aria-label", "Exported functions in rray over time, one dot per merged pull request");

  svg
    .append("g")
    .attr("class", "tl-axis tl-axis-y")
    .attr("transform", `translate(${MARGIN.left},0)`)
    .call(
      d3
        .axisLeft(y)
        .ticks(height / 60)
        .tickSize(-(width - MARGIN.left - MARGIN.right))
        .tickPadding(6),
    )
    .call((g) => g.select(".domain").remove());

  svg
    .append("g")
    .attr("class", "tl-axis tl-axis-x")
    .attr("transform", `translate(0,${height - MARGIN.bottom})`)
    .call(d3.axisBottom(x).ticks(tickInterval(x)).tickFormat(d3.timeFormat("%b %-d")).tickSizeOuter(0));

  const line = d3
    .line()
    .curve(d3.curveStepAfter)
    .x((step) => x(step.date))
    .y((step) => y(step.exports));

  svg.append("path").attr("class", "tl-line").attr("d", line(model.steps));

  // Small dots first so larger ones draw on top
  const prs = d3.sort(model.prs, (pr) => pr.kind !== "other");

  const dots = svg
    .append("g")
    .selectAll("g")
    .data(prs)
    .join("g")
    .attr("class", (pr) => `tl-dot tl-dot-${pr.kind}`)
    .attr("transform", (pr) => `translate(${x(pr.date)},${y(pr.exports)})`);

  dots.append("title").text(describe);

  dots
    .append("circle")
    .attr("r", (pr) => RADIUS[pr.kind])
    .style("fill", fill);

  placeLabels(svg, model, prs, { x, y, width, height });
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
function placeLabels(svg, model, prs, { x, y, width, height }) {
  const bounds = {
    x0: MARGIN.left,
    y0: 0,
    x1: width - MARGIN.right,
    y1: height - MARGIN.bottom,
  };

  const exportsAt = (date) => {
    const i = d3.bisector((step) => step.date).right(model.steps, date) - 1;
    return model.steps[Math.max(i, 0)].exports;
  };

  // The step line only rises, so over a box it spans from its height at the left edge up to its height at the right edge
  const hitsLine = (box) => {
    const bottom = y(exportsAt(x.invert(box.x0)));
    const top = y(exportsAt(x.invert(box.x1)));
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

  const labeled = model.ranked.slice(0, width < NARROW_WIDTH ? LABEL_COUNT.narrow : LABEL_COUNT.wide);

  const layer = svg.append("g").attr("class", "tl-labels");

  for (const pr of labeled) {
    const text = layer.append("text").attr("class", "tl-label").text(pr.label);
    const bbox = text.node().getBBox();

    const cx = x(pr.date);
    const cy = y(pr.exports);
    const r = RADIUS[pr.kind];

    const box = candidates(cx, cy, r, bbox.width, bbox.height).find((box) => fits(pr, box));

    if (!box) {
      text.remove();
      continue;
    }

    boxes.push(box);
    text.attr("x", box.x0 - bbox.x).attr("y", box.y0 - bbox.y);

    leaders.push(box.leader);
    const [[x1, y1], [x2, y2]] = box.leader;
    layer
      .insert("line", "text")
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

  key("Adds exports", (item) => swatch(item, "add"));
  key("Other", (item) => swatch(item, "other"));

  const ramp = legend.append("span").attr("class", "tl-key");
  ramp.append("span").text("Simple");
  ramp.append("span").attr("class", "tl-ramp");
  ramp.append("span").text("Complex");

  key("Unknown", (item) => swatch(item, "add").style("fill", "var(--tl-unknown)"));
}
