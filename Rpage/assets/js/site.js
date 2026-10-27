/* ============================================================================
   刷起 SHUAQI · 交互脚本
   依赖：无。全部为原生 DOM / CSS 动画 / Canvas 2D。
   章节：0 配置 · 1 导航 · 2 入场 · 3 视差 · 4 切题 · 5 判题 · 6 二刷
        7 试写画布 · 8 热力图 · 9 色系
   ========================================================================= */
(function () {
  "use strict";

  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var $ = function (sel, root) { return (root || document).querySelector(sel); };
  var $$ = function (sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); };

  /* ---------------------------------------------------------------- 0 · 配置 */
  var cfg = window.SHUAQI || {};
  if (cfg.apkUrl) {
    $$("[data-apk-link]").forEach(function (a) { a.setAttribute("href", cfg.apkUrl); });
  }
  if (cfg.github) {
    $$('[data-link="github"]').forEach(function (a) {
      a.setAttribute("href", cfg.github);
      a.hidden = false;
    });
  }

  /* ---------------------------------------------------------------- 1 · 导航 */
  (function nav() {
    var el = $("[data-nav]");
    var progress = $("[data-progress]");
    var links = $$(".nav-links a");
    var burger = $("[data-burger]");
    if (!el) return;

    function onScroll() {
      var y = window.scrollY || window.pageYOffset;
      el.classList.toggle("is-scrolled", y > 10);
      var bar = document.querySelector(".scroll-progress");
      if (bar) bar.classList.toggle("is-on", y > 40);
      if (progress) {
        var h = document.documentElement.scrollHeight - window.innerHeight;
        progress.style.width = (h > 0 ? Math.min(1, y / h) : 0) * 100 + "%";
      }
    }
    window.addEventListener("scroll", onScroll, { passive: true });
    onScroll();

    if (burger) {
      burger.addEventListener("click", function () {
        var open = el.classList.toggle("is-open");
        burger.setAttribute("aria-expanded", String(open));
      });
      links.forEach(function (a) {
        a.addEventListener("click", function () {
          el.classList.remove("is-open");
          burger.setAttribute("aria-expanded", "false");
        });
      });
    }

    // 当前章节高亮
    var ids = ["split", "grade", "redo", "write", "records", "faq"];
    var sections = ids.map(function (id) { return document.getElementById(id); }).filter(Boolean);
    if ("IntersectionObserver" in window && sections.length) {
      var shown = {};
      var io = new IntersectionObserver(function (entries) {
        entries.forEach(function (en) {
          shown[en.target.id] = en.isIntersecting;
        });
        var current = null;
        ids.forEach(function (id) { if (shown[id]) current = id; });
        links.forEach(function (a) {
          a.classList.toggle("is-active", !!current && a.getAttribute("href") === "#" + current);
        });
      }, { rootMargin: "-45% 0px -50% 0px" });
      sections.forEach(function (s) { io.observe(s); });
    }
  })();

  /* ---------------------------------------------------------------- 2 · 入场 */
  (function reveal() {
    var items = $$("[data-reveal]");
    if (!items.length) return;
    if (reduceMotion || !("IntersectionObserver" in window)) {
      items.forEach(function (n) { n.classList.add("is-in"); });
      return;
    }
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) {
        if (en.isIntersecting) {
          en.target.classList.add("is-in");
          io.unobserve(en.target);
        }
      });
    }, { threshold: 0.12, rootMargin: "0px 0px -6% 0px" });
    items.forEach(function (n) { io.observe(n); });
  })();

  /* ---------------------------------------------------------------- 3 · 视差 */
  (function parallax() {
    var host = $("[data-parallax]");
    if (!host || reduceMotion || window.matchMedia("(hover: none)").matches) return;
    var raf = 0, tx = 0, ty = 0, cx = 0, cy = 0;

    function loop() {
      cx += (tx - cx) * 0.08;
      cy += (ty - cy) * 0.08;
      host.style.transform = "translate3d(" + cx.toFixed(2) + "px," + cy.toFixed(2) + "px,0)";
      if (Math.abs(tx - cx) > 0.05 || Math.abs(ty - cy) > 0.05) {
        raf = requestAnimationFrame(loop);
      } else {
        raf = 0;
      }
    }
    function kick() { if (!raf) raf = requestAnimationFrame(loop); }

    window.addEventListener("pointermove", function (e) {
      if (e.pointerType === "touch") return;
      tx = (e.clientX / window.innerWidth - 0.5) * 18;
      ty = (e.clientY / window.innerHeight - 0.5) * 12;
      kick();
    }, { passive: true });
  })();

  /* ---------------------------------------------------------------- 4 · 切题演示 */
  (function splitDemo() {
    var demo = $('[data-demo="split"]');
    if (!demo) return;
    var paper = $("[data-split-paper]", demo);
    var layer = $("[data-region-layer]", demo);
    var status = $("[data-split-status]", demo);
    var statusText = $("[data-split-status-text]", demo);
    var replay = $("[data-split-replay]", demo);
    var qs = $$("[data-q]", demo);
    var rects = [];
    var timers = [];

    function clearTimers() {
      timers.forEach(clearTimeout);
      timers = [];
    }
    function later(fn, ms) { timers.push(setTimeout(fn, ms)); }

    function layout() {
      var pr = paper.getBoundingClientRect();
      if (!pr.width) return;
      layer.setAttribute("viewBox", "0 0 " + pr.width + " " + pr.height);
      qs.forEach(function (q, i) {
        var r = q.getBoundingClientRect();
        var rect = rects[i];
        if (!rect) {
          rect = document.createElementNS("http://www.w3.org/2000/svg", "rect");
          rect.setAttribute("rx", "10");
          rect.setAttribute("pathLength", "1");
          rect.classList.add("region-rect");
          rect.style.transitionDelay = i * 85 + "ms";
          layer.appendChild(rect);
          rects[i] = rect;
        }
        rect.setAttribute("x", (r.left - pr.left - 7).toFixed(1));
        rect.setAttribute("y", (r.top - pr.top - 4).toFixed(1));
        rect.setAttribute("width", (r.width + 14).toFixed(1));
        rect.setAttribute("height", (r.height + 8).toFixed(1));
      });
    }

    function reset() {
      clearTimers();
      paper.classList.remove("is-drawn");
      status.classList.remove("is-on");
      statusText.textContent = "正在识别页面结构…";
    }

    function play() {
      reset();
      layout();
      // 让浏览器先落一次"未画"的状态，再触发描边
      requestAnimationFrame(function () {
        requestAnimationFrame(function () {
          paper.classList.add("is-drawn");
          later(function () {
            statusText.textContent = "已切出 " + qs.length + " 道题 · 可拖动、可锁定";
            status.classList.add("is-on");
          }, qs.length * 85 + 460);
        });
      });
    }

    var started = false;
    function startOnce() {
      if (started) return;
      started = true;
      if (reduceMotion) {
        layout();
        paper.classList.add("is-drawn");
        statusText.textContent = "已切出 " + qs.length + " 道题 · 可拖动、可锁定";
        status.classList.add("is-on");
        return;
      }
      play();
    }

    if ("IntersectionObserver" in window) {
      var io = new IntersectionObserver(function (entries) {
        entries.forEach(function (en) {
          if (en.isIntersecting) { startOnce(); io.disconnect(); }
        });
      }, { threshold: 0.3 });
      io.observe(demo);
    } else {
      startOnce();
    }

    replay.addEventListener("click", function () {
      if (reduceMotion) return;
      clearTimers();
      started = true;
      play();
    });

    if ("ResizeObserver" in window) {
      var ro = new ResizeObserver(function () { layout(); });
      ro.observe(paper);
    }
    window.addEventListener("resize", layout);
  })();

  /* ---------------------------------------------------------------- 5 · 判题演示 */
  (function gradeDemo() {
    var demo = $('[data-demo="grade"]');
    if (!demo) return;
    var rows = $$(".grade-list li", demo);
    var runBtn = $("[data-grade-run]", demo);
    var tip = $("[data-grade-tip]", demo);
    var counters = {};
    $$("[data-count]", demo).forEach(function (n) { counters[n.getAttribute("data-count")] = n; });
    var timers = [];

    function clearTimers() { timers.forEach(clearTimeout); timers = []; }
    function later(fn, ms) { timers.push(setTimeout(fn, ms)); }

    function target(verdict) {
      return rows.filter(function (r) { return r.getAttribute("data-verdict") === verdict; }).length;
    }

    function countTo(el, to) {
      var from = parseInt(el.textContent, 10) || 0;
      if (reduceMotion) { el.textContent = to; return; }
      var t0 = performance.now(), dur = 420;
      (function tick(t) {
        var p = Math.min(1, (t - t0) / dur);
        el.textContent = Math.round(from + (to - from) * (1 - Math.pow(1 - p, 3)));
        if (p < 1) requestAnimationFrame(tick);
      })(performance.now());
    }

    function reset() {
      clearTimers();
      rows.forEach(function (r) { r.classList.remove("is-on"); });
      Object.keys(counters).forEach(function (k) { counters[k].textContent = "0"; });
      tip.classList.remove("is-on");
      runBtn.classList.remove("is-pressed");
    }

    function play() {
      reset();
      if (reduceMotion) {
        rows.forEach(function (r) { r.classList.add("is-on"); });
        Object.keys(counters).forEach(function (k) { counters[k].textContent = target(k); });
        tip.classList.add("is-on");
        return;
      }
      runBtn.classList.add("is-pressed");
      later(function () { runBtn.classList.remove("is-pressed"); }, 180);

      rows.forEach(function (r, i) {
        later(function () {
          r.classList.add("is-on");
          var v = r.getAttribute("data-verdict");
          if (counters[v]) countTo(counters[v], target(v));
        }, 360 + i * 145);
      });
      later(function () { tip.classList.add("is-on"); }, 360 + rows.length * 145 + 220);
    }

    var started = false;
    if ("IntersectionObserver" in window) {
      var io = new IntersectionObserver(function (entries) {
        entries.forEach(function (en) {
          if (en.isIntersecting && !started) { started = true; play(); io.disconnect(); }
        });
      }, { threshold: 0.4 });
      io.observe(demo);
    } else {
      started = true;
      play();
    }
    runBtn.addEventListener("click", function () { started = true; play(); });
  })();

  /* ---------------------------------------------------------------- 6 · 二刷演示 */
  (function redoDemo() {
    var demo = $('[data-demo="redo"]');
    if (!demo) return;
    var replay = $("[data-redo-replay]", demo);
    var timers = [];

    function clearTimers() { timers.forEach(clearTimeout); timers = []; }
    function later(fn, ms) { timers.push(setTimeout(fn, ms)); }

    function reset() {
      clearTimers();
      demo.classList.remove("stage-picked", "stage-stacked", "stage-sheet");
    }

    function play() {
      reset();
      if (reduceMotion) {
        demo.classList.add("stage-sheet");
        return;
      }
      later(function () { demo.classList.add("stage-picked"); }, 420);
      later(function () { demo.classList.add("stage-stacked"); }, 1500);
      later(function () { demo.classList.add("stage-sheet"); }, 2500);
    }

    var started = false;
    if ("IntersectionObserver" in window) {
      var io = new IntersectionObserver(function (entries) {
        entries.forEach(function (en) {
          if (en.isIntersecting && !started) { started = true; play(); io.disconnect(); }
        });
      }, { threshold: 0.4 });
      io.observe(demo);
    } else {
      started = true;
      play();
    }
    replay.addEventListener("click", function () { started = true; play(); });
  })();

  /* ---------------------------------------------------------------- 7 · 试写画布 */
  (function inkpad() {
    var pad = $("[data-pad]");
    var canvas = $("[data-pad-canvas]");
    if (!pad || !canvas || !canvas.getContext) return;

    var ctx = canvas.getContext("2d");
    var dpr = Math.min(window.devicePixelRatio || 1, 2.5);
    var strokes = [];
    var undoStack = [];
    var drawing = null;
    var erasing = false;
    var hint = $("[data-pad-hint]");
    var lastErase = null;
    var tool = "pen";
    var color = "#16181C";

    var W = 0, H = 0;

    function resize() {
      var r = pad.getBoundingClientRect();
      if (!r.width) return;
      W = r.width;
      H = r.height;
      canvas.width = Math.round(W * dpr);
      canvas.height = Math.round(H * dpr);
      canvas.style.width = W + "px";
      canvas.style.height = H + "px";
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      render();
    }

    function pressureOf(e) {
      if (e.pointerType === "pen" && e.pressure > 0) return Math.max(0.25, e.pressure);
      if (e.pointerType === "touch" && e.pressure > 0 && e.pressure !== 0.5) return Math.max(0.3, e.pressure);
      return 0.55;
    }

    function pos(e) {
      var r = canvas.getBoundingClientRect();
      return { x: e.clientX - r.left, y: e.clientY - r.top, p: pressureOf(e) };
    }

    function widthFor(s, p) {
      var base = s.tool === "marker" ? 22 : 3.5;
      if (s.tool === "marker") return base;
      return base * (0.4 + 0.95 * p);
    }

    function strokeStyleFor(s) {
      if (s.tool === "marker") {
        var c = s.color;
        return hexToRgba(c, 0.3);
      }
      return s.color;
    }

    function hexToRgba(hex, a) {
      var h = hex.replace("#", "");
      if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2];
      var n = parseInt(h, 16);
      return "rgba(" + ((n >> 16) & 255) + "," + ((n >> 8) & 255) + "," + (n & 255) + "," + a + ")";
    }

    function drawStroke(s) {
      var pts = s.points;
      if (!pts || pts.length === 0) return;
      ctx.save();
      ctx.lineCap = "round";
      ctx.lineJoin = "round";
      ctx.strokeStyle = strokeStyleFor(s);
      if (s.tool === "marker") ctx.globalCompositeOperation = "source-over";

      if (pts.length === 1) {
        var w0 = widthFor(s, pts[0].p);
        ctx.beginPath();
        ctx.arc(pts[0].x, pts[0].y, w0 / 2, 0, Math.PI * 2);
        ctx.fillStyle = ctx.strokeStyle;
        ctx.fill();
        ctx.restore();
        return;
      }

      for (var i = 1; i < pts.length; i++) {
        var a = pts[i - 1], b = pts[i];
        ctx.beginPath();
        ctx.lineWidth = widthFor(s, (a.p + b.p) / 2);
        ctx.moveTo(a.x, a.y);
        ctx.lineTo(b.x, b.y);
        ctx.stroke();
      }
      ctx.restore();
    }

    function render() {
      ctx.clearRect(0, 0, W, H);
      for (var i = 0; i < strokes.length; i++) drawStroke(strokes[i]);
      if (drawing) drawStroke(drawing);
    }

    function pushUndo() {
      undoStack.push(JSON.stringify(strokes));
      if (undoStack.length > 24) undoStack.shift();
    }

    function dist(a, b) {
      var dx = a.x - b.x, dy = a.y - b.y;
      return Math.sqrt(dx * dx + dy * dy);
    }

    /* 局部橡皮：把一笔按擦除半径切开，保留两侧的段 */
    function eraseAt(pt, radius) {
      var next = [];
      var touched = false;
      for (var i = 0; i < strokes.length; i++) {
        var s = strokes[i];
        var kept = [];
        var pieces = [];
        for (var j = 0; j < s.points.length; j++) {
          var p = s.points[j];
          if (dist(p, pt) <= radius) {
            touched = true;
            if (kept.length > 1) pieces.push(kept);
            kept = [];
          } else {
            kept.push(p);
          }
        }
        if (kept.length > 1) pieces.push(kept);
        if (pieces.length === 1 && pieces[0].length === s.points.length) {
          next.push(s);
        } else {
          pieces.forEach(function (pp) {
            next.push({ tool: s.tool, color: s.color, points: pp });
          });
        }
      }
      if (touched) {
        strokes = next;
        render();
      }
    }

    canvas.addEventListener("pointerdown", function (e) {
      e.preventDefault();
      if (canvas.setPointerCapture) {
        try { canvas.setPointerCapture(e.pointerId); } catch (err) { /* 合成事件没有真实指针 */ }
      }
      if (hint) hint.classList.add("is-hidden");

      if (tool === "eraser") {
        pushUndo();
        erasing = true;
        lastErase = null;
        var p0 = pos(e);
        eraseAt(p0, 13);
        lastErase = p0;
        return;
      }
      drawing = { tool: tool, color: color, points: [pos(e)] };
      render();
    });

    canvas.addEventListener("pointermove", function (e) {
      if (!drawing && !erasing) return;
      e.preventDefault();
      var pt = pos(e);

      if (erasing) {
        if (!lastErase || dist(lastErase, pt) > 4) {
          eraseAt(pt, 13);
          lastErase = pt;
        }
        return;
      }
      // 距离过滤：避免同一点塞太多采样
      var last = drawing.points[drawing.points.length - 1];
      if (dist(last, pt) < 0.7) return;
      drawing.points.push(pt);
      render();
    });

    function endStroke(e) {
      if (erasing) {
        erasing = false;
        lastErase = null;
        return;
      }
      if (!drawing) return;
      if (drawing.points.length > 0) {
        pushUndo();
        strokes.push(drawing);
      }
      drawing = null;
      render();
      if (e && e.pointerId && canvas.releasePointerCapture) {
        try { canvas.releasePointerCapture(e.pointerId); } catch (err) { /* ignore */ }
      }
    }
    canvas.addEventListener("pointerup", endStroke);
    canvas.addEventListener("pointercancel", endStroke);
    canvas.addEventListener("pointerleave", function (e) {
      if (drawing && e.buttons === 0) endStroke(e);
    });

    // 工具切换
    $$("[data-tool]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        tool = btn.getAttribute("data-tool");
        $$("[data-tool]").forEach(function (b) {
          var on = b === btn;
          b.classList.toggle("is-active", on);
          b.setAttribute("aria-pressed", String(on));
        });
        canvas.style.cursor = tool === "eraser" ? "cell" : "crosshair";
      });
    });

    // 颜色
    $$("[data-color]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        color = btn.getAttribute("data-color");
        $$("[data-color]").forEach(function (b) {
          var on = b === btn;
          b.classList.toggle("is-active", on);
          b.setAttribute("aria-pressed", String(on));
        });
        if (tool === "eraser") {
          tool = "pen";
          $$("[data-tool]").forEach(function (b) {
            var on = b.getAttribute("data-tool") === "pen";
            b.classList.toggle("is-active", on);
            b.setAttribute("aria-pressed", String(on));
          });
        }
      });
    });

    // 撤销 / 清空
    var undoBtn = $("[data-pad-undo]");
    if (undoBtn) {
      undoBtn.addEventListener("click", function () {
        if (!undoStack.length) return;
        strokes = JSON.parse(undoStack.pop());
        render();
      });
    }
    var clearBtn = $("[data-pad-clear]");
    if (clearBtn) {
      clearBtn.addEventListener("click", function () {
        if (!strokes.length) return;
        pushUndo();
        strokes = [];
        render();
      });
    }

    // 纸张
    var paperLabels = { original: "原纸", warm: "暖白", ivory: "象牙", gray: "浅灰", green: "浅绿", night: "夜读" };
    $$("[data-paper]").forEach(function (btn) {
      if (btn.tagName !== "BUTTON") return;
      btn.addEventListener("click", function () {
        var key = btn.getAttribute("data-paper");
        pad.setAttribute("data-paper", key);
        $$(".paper-dot").forEach(function (b) {
          var on = b === btn;
          b.classList.toggle("is-active", on);
          b.setAttribute("aria-pressed", String(on));
        });
        // 夜读纸上默认换成暖白墨色
        if (key === "night" && color === "#16181C") {
          color = "#E9E3D5";
          $$("[data-color]").forEach(function (b) {
            var on = b.getAttribute("data-color") === color;
            b.classList.toggle("is-active", on);
            b.setAttribute("aria-pressed", String(on));
          });
        } else if (key !== "night" && color === "#E9E3D5") {
          color = "#16181C";
          $$("[data-color]").forEach(function (b) {
            var on = b.getAttribute("data-color") === color;
            b.classList.toggle("is-active", on);
            b.setAttribute("aria-pressed", String(on));
          });
        }
        render();
      });
    });

    if ("ResizeObserver" in window) {
      var ro = new ResizeObserver(function () { resize(); });
      ro.observe(pad);
    }
    window.addEventListener("resize", resize);
    resize();
  })();

  /* ---------------------------------------------------------------- 8 · 热力图 */
  (function heatmap() {
    var grid = $("[data-heat]");
    if (!grid) return;
    var months = $("[data-heat-months]");
    var tip = $("[data-heat-tip]");
    var sub = $("[data-heat-sub]");

    var WEEKS = 26;
    var today = new Date();
    today.setHours(0, 0, 0, 0);
    // 本周一
    var monday = new Date(today);
    var dow = (today.getDay() + 6) % 7;
    monday.setDate(today.getDate() - dow);

    var start = new Date(monday);
    start.setDate(monday.getDate() - (WEEKS - 1) * 7);

    // 确定性伪随机：同一份页面每次刷新图案一致
    var seed = 20261026;
    function rnd() {
      seed = (seed * 1664525 + 1013904223) % 4294967296;
      return seed / 4294967296;
    }

    var cells = [];
    var frag = document.createDocumentFragment();
    var monthNames = ["1月", "2月", "3月", "4月", "5月", "6月", "7月", "8月", "9月", "10月", "11月", "12月"];
    var lastMonth = -1;

    for (var w = 0; w < WEEKS; w++) {
      var weekStart = new Date(start);
      weekStart.setDate(start.getDate() + w * 7);
      if (weekStart.getMonth() !== lastMonth) {
        lastMonth = weekStart.getMonth();
        if (months) {
          var lab = document.createElement("span");
          lab.textContent = monthNames[lastMonth];
          lab.style.gridColumn = w + 1 + " / span 4";
          months.appendChild(lab);
        }
      }
      for (var d = 0; d < 7; d++) {
        var date = new Date(weekStart);
        date.setDate(weekStart.getDate() + d);
        var future = date > today;
        var lvl = 0;
        if (!future) {
          var r = rnd();
          if (r > 0.66) {
            var k = rnd();
            lvl = k > 0.95 ? 5 : k > 0.84 ? 4 : k > 0.58 ? 3 : k > 0.3 ? 2 : 1;
          }
        }
        var cell = document.createElement("i");
        cell.className = "heat-cell";
        cell.setAttribute("data-level", String(lvl));
        cell.setAttribute("data-date", date.getTime());
        cell.setAttribute("data-future", future ? "1" : "0");
        if (date.getTime() === today.getTime()) cell.classList.add("is-today");
        cell.__count = lvl === 0 ? 0 : lvl * 2 + Math.floor(rnd() * 3);
        frag.appendChild(cell);
        cells.push(cell);
      }
    }
    grid.appendChild(frag);

    if (sub) {
      var fmt = function (dt) { return dt.getFullYear() + " 年 " + (dt.getMonth() + 1) + " 月"; };
      sub.textContent = fmt(start) + " — " + fmt(today);
    }

    function dateText(ts) {
      var dt = new Date(ts);
      return (dt.getMonth() + 1) + " 月 " + dt.getDate() + " 日";
    }
    grid.addEventListener("pointerover", function (e) {
      var c = e.target.closest(".heat-cell");
      if (!c || !tip) return;
      if (c.getAttribute("data-future") === "1") return;
      var n = c.__count || 0;
      tip.textContent = dateText(Number(c.getAttribute("data-date"))) + " · " + (n ? n + " 题" : "没有记录");
    });

    function show() {
      cells.forEach(function (c, i) {
        setTimeout(function () { c.classList.add("is-in"); }, reduceMotion ? 0 : i * 3);
      });
    }
    if ("IntersectionObserver" in window && !reduceMotion) {
      var io = new IntersectionObserver(function (entries) {
        entries.forEach(function (en) {
          if (en.isIntersecting) { show(); io.disconnect(); }
        });
      }, { threshold: 0.25 });
      io.observe(grid);
    } else {
      show();
    }
  })();

  /* ---------------------------------------------------------------- 9 · 色系 */
  (function accents() {
    var KEY = "shuaqi.preview.accent";
    var root = document.documentElement;
    var dots = $$("[data-accent]");

    function apply(name, persist) {
      root.setAttribute("data-accent", name);
      dots.forEach(function (d) {
        d.setAttribute("aria-pressed", String(d.getAttribute("data-accent") === name));
      });
      if (persist) {
        try { localStorage.setItem(KEY, name); } catch (e) { /* ignore */ }
      }
    }

    var saved = "azure";
    try { saved = localStorage.getItem(KEY) || "azure"; } catch (e) { /* ignore */ }
    apply(saved, false);

    dots.forEach(function (d) {
      d.addEventListener("click", function () { apply(d.getAttribute("data-accent"), true); });
    });
  })();

  /* ---------------------------------------------------------------- 10 · 细节 */
  (function misc() {
    // 同一时间只展开一个问答
    var all = $$(".faq-list details");
    all.forEach(function (d) {
      d.addEventListener("toggle", function () {
        if (!d.open) return;
        all.forEach(function (o) { if (o !== d) o.open = false; });
      });
    });

    // 年份
    var y = $("[data-year]");
    if (y) y.textContent = String(new Date().getFullYear());
  })();
})();
