// The About card: the machine as a sigil you can knead into a strip and
// back. Drag sideways, click, Space or the buttons switch shapes; hovering a
// ring or a row (or the arrow keys) says what it is in the footer.
//
// A port of AboutCard.qml. One canvas draws every frame (rings, dividers,
// list icons); the words are positioned spans on top. The app (main.swift)
// drives it through window.MachineMark.
(function() {
"use strict"

var S = Sigil
var UNIT = 14, LINE = 18
var stage = document.getElementById("stage"), cv = document.getElementById("cv"), ctx = cv.getContext("2d")
var wordsEl = document.getElementById("words"), hlEl = document.getElementById("hl"), loadingEl = document.getElementById("loading")
var statusEl = document.getElementById("status"), bSigil = document.getElementById("bSigil"), bStrip = document.getElementById("bStrip")
var MONO = '"SF Mono", ui-monospace, Menlo, monospace'

// One reading from the app (see Collector.swift), and when it was taken.
var machine = null, readAt = 0, loadError = "", running = false
var pal = S.palette({})

// Each ring's shape: 0 = strip, 1 = sigil, eased one ring after another.
var cur = S.RINGS.map(function() { return 1 })
var target = 1, anim = null, drag = null, dragging = false
var hi = -1, say = ""
var builtAt = -1e9, building = false, buildTimer = 0
var geo = null, factsKey = ""
var texts = [], textsAt = 0, valW = 0, shortW = [], headW = { hw: 0, sw: 0, age: 0 }
var markCache = {}
var lastLayout = null, lastDraw = 0, dirty = true

function now() { return Date.now() }
function post(msg) { try { window.webkit.messageHandlers.mark.postMessage(msg) } catch (e) {} }
function allAt(v) { for (var i = 0; i < cur.length; i++) if (cur[i] !== v) return false; return true }
function shape() { return S.average(cur) }
function geoKey(m) { return [m.host, m.cpu.name, m.gpu.name, m.installed, m.cpu.threads, m.packages.count, m.upgrades].join("|") }
// Everything except the values the live reading refreshes.
function slowKey(m) {
    var c = JSON.parse(JSON.stringify(m))
    delete c.memory; delete c.uptime; delete c.now
    if (c.gpu) delete c.gpu.usage
    return JSON.stringify(c)
}

// ------------------------------------------------------------ text measuring

var measure = document.createElement("canvas").getContext("2d")
function textW(s, px, bold) { measure.font = (bold ? "700 " : "") + px + "px " + MONO; return measure.measureText(s).width }

// ------------------------------------------------------------ words

var heads = {}, rows = []
S.CATS.forEach(function(cat) {
    var el = document.createElement("span")
    el.className = "head"
    el.textContent = S.CAT_NAME[cat]
    wordsEl.appendChild(el)
    heads[cat] = el
    headW[cat] = Math.ceil(textW(S.CAT_NAME[cat], 12.5, true))
})
S.RINGS.forEach(function(r) {
    var row = { name: document.createElement("span"), short: document.createElement("span"), long: document.createElement("span") }
    row.name.className = "name"
    row.name.textContent = r.name
    wordsEl.appendChild(row.name); wordsEl.appendChild(row.short); wordsEl.appendChild(row.long)
    rows.push(row)
})

function refreshTexts(t) {
    if (!machine) return
    var f = S.facts(machine, Math.max(0, (t - readAt) / 1000))
    texts = S.RINGS.map(function(r) { return S.text(r.k, machine, f, machine.theme) })
    textsAt = t
    var widest = 0
    texts.forEach(function(tx, i) {
        if (rows[i].short.textContent !== tx.s) rows[i].short.textContent = tx.s
        if (rows[i].long.textContent !== tx.l) rows[i].long.textContent = tx.l
        shortW[i] = textW(tx.s, UNIT)
        widest = Math.max(widest, shortW[i])
    })
    widest = Math.ceil(widest)
    if (Math.abs(widest - valW) > 2) valW = widest
    // The live dials (memory, uptime, updated) draw from the facts: new marks.
    markCache = {}
    showStatus()
}

function statusText() {
    if (say) return say
    if (!machine) return loadError || "Reading this Mac…"
    if (hi < 0) return ""
    return texts[hi] ? texts[hi].how : ""
}
function showStatus() { statusEl.textContent = statusText() }

function header() {
    var m = machine
    document.getElementById("host").textContent = m ? m.host : " "
    var os = document.getElementById("osline"), model = document.getElementById("modelline")
    var v = m && m.os.version ? "macOS " + (m.os.name ? m.os.name + " " : "") + m.os.version : "macOS"
    os.textContent = v
    os.dataset.explain = v + (m && m.os.build ? " (" + m.os.build + ")" : "") + (m && m.kernel ? ", running on Darwin " + m.kernel : "") + "."
    var name = m ? m.os.model || m.os.modelId : ""
    model.textContent = name ? name + (m.os.modelId && m.os.model ? " · " + m.os.modelId : "") : ""
    model.dataset.explain = name ? "This is a " + name + (m.os.modelId ? " (model " + m.os.modelId + ")" : "") + (m.cpu.name ? " with an " + m.cpu.name + "." : ".") : ""
}
document.querySelectorAll(".hover").forEach(function(el) {
    el.addEventListener("mouseenter", function() { say = el.dataset.explain || ""; showStatus() })
    el.addEventListener("mouseleave", function() { say = ""; showStatus() })
})

// ------------------------------------------------------------ shapes

// A knead, once started, plays through: input that would start another is
// ignored until it has settled, and so is asking for the shape it already is.
function go(to) {
    if (anim || drag || dragging || allAt(to)) return
    target = to
    anim = { from: cur.slice(), to: to, t0: -1, fast: false }
    buttons()
}

// A drag let go settles on the nearer shape.
function settle() {
    target = Math.round(shape())
    anim = { from: cur.slice(), to: target, t0: -1, fast: true }
    buttons()
}

function step(t) {
    if (!anim) return
    if (anim.t0 < 0) anim.t0 = t
    var done = true, next = cur.slice(), n = next.length
    for (var i = 0; i < n; i++) {
        var order = anim.to === 1 ? i : n - 1 - i
        var dl = anim.fast ? 0 : order * 40, dur = anim.fast ? 280 : 820
        var k = S.ease(S.clamp((t - anim.t0 - dl) / dur, 0, 1))
        if (k < 1) done = false
        next[i] = S.lerp(anim.from[i], anim.to, k)
    }
    cur = next
    if (done) anim = null
}

function buttons() {
    bSigil.classList.toggle("sel", target === 1)
    bStrip.classList.toggle("sel", target === 0)
}

// ------------------------------------------------------------ drawing

function state(t) {
    return { machine: machine, facts: S.facts(machine, Math.max(0, (t - readAt) / 1000)), geo: geo, pal: pal,
             cur: cur, hi: hi, builtAt: builtAt, unit: UNIT, headW: headW, markCache: markCache }
}

function layoutNow() { return S.layout(stage.clientWidth, stage.clientHeight, { unit: UNIT, valW: valW }) }

function draw(t) {
    var w = stage.clientWidth, h = stage.clientHeight, dpr = window.devicePixelRatio || 1
    var pw = Math.max(1, Math.round(w * dpr)), ph = Math.max(1, Math.round(h * dpr))
    if (cv.width !== pw || cv.height !== ph) { cv.width = pw; cv.height = ph }
    ctx.setTransform(1, 0, 0, 1, 0, 0)
    ctx.clearRect(0, 0, pw, ph)
    if (!machine || !geo) { lastLayout = null; placeWords(null); return }
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    var Y = lastLayout = layoutNow()
    S.paint(ctx, Y, t, state(t))
    placeWords(Y)
}

function place(el, x, y, opacity, maxW) {
    el.style.transform = "translate(" + x.toFixed(2) + "px," + (y - LINE / 2).toFixed(2) + "px)"
    el.style.opacity = opacity
    el.style.visibility = opacity > 0.01 ? "visible" : "hidden"
    if (maxW !== undefined) el.style.maxWidth = Math.max(0, maxW) + "px"
}

function placeWords(Y) {
    wordsEl.style.display = Y ? "" : "none"
    loadingEl.style.display = machine ? "none" : ""
    if (!Y) { hlEl.style.display = "none"; return }
    var sh = shape()
    S.CATS.forEach(function(cat) {
        var p = S.headPos(Y, cat, sh), el = heads[cat]
        el.style.color = pal.cat[cat]
        place(el, p[0], p[1], hi < 0 || S.RINGS[hi].cat === cat ? 1 : S.DIM_TEXT)
    })
    for (var i = 0; i < S.RINGS.length; i++) {
        var k = cur[i], row = rows[i], isHi = hi === i
        var p = S.textPos(Y, i, k, UNIT, Math.min(shortW[i] || 0, valW))
        var dim = hi < 0 || isHi ? 1 : S.DIM_TEXT
        // Values never run past their column: the strip's, or the list's width.
        var room = S.lerp(valW, Y.infoW - UNIT * 9.2 - 10, k)
        row.name.classList.toggle("hi", isHi)
        place(row.name, p.nameX, p.y, dim)
        place(row.short, p.valueX, p.y, dim * S.clamp(1 - 2.2 * k, 0, 1), room + 1)
        place(row.long, p.valueX, p.y, dim * S.clamp(2.2 * k - 1.2, 0, 1), room)
    }
    // The picked row, as menus mark their cursor row; it slides with its row.
    if (hi >= 0) {
        var kk = cur[hi], rowH = S.lerp(Y.rh, Y.ih, kk)
        hlEl.style.display = "block"
        hlEl.style.transform = "translate(" + S.lerp(4, Y.ix, kk) + "px," + (S.lerp(Y.rowY[hi], Y.yI(S.LIST_AT[hi]), kk) - rowH / 2 + 1) + "px)"
        hlEl.style.width = S.lerp(Y.w - 8, Y.infoW - 10, kk) + "px"
        hlEl.style.height = Math.max(0, rowH - 2) + "px"
    } else hlEl.style.display = "none"
}

// While the shape changes, a frame for every display refresh (60 fps at
// most); at rest the rings turn slowly, so 30 a second is plenty.
function frame() {
    requestAnimationFrame(frame)
    if (!running) return
    var t = now(), moving = anim || dragging || building || dirty
    if (t - lastDraw < (moving ? 15 : 32)) return
    lastDraw = t
    dirty = false
    step(t)
    if (machine && t - textsAt > 5000) refreshTexts(t)
    draw(t)
}
requestAnimationFrame(frame)

// ------------------------------------------------------------ input

function key(e) {
    var k = e.key
    if (k === "Escape") { post({ type: "close" }); return true }
    if (k === " " || k === "Enter") { go(1 - target); return true }
    // Left to right reads sigil → strip, like the buttons: → unrolls it.
    if (k === "ArrowLeft" || k === "h") { go(1); return true }
    if (k === "ArrowRight" || k === "l") { go(0); return true }
    if (k === "ArrowDown" || k === "j") { hi = (hi + 1) % S.RINGS.length; showStatus(); dirty = true; return true }
    if (k === "ArrowUp" || k === "k") { hi = hi <= 0 ? S.RINGS.length - 1 : hi - 1; showStatus(); dirty = true; return true }
    return false
}
document.addEventListener("keydown", function(e) { if (!e.metaKey && !e.ctrlKey && key(e)) e.preventDefault() })

function local(e) { var r = stage.getBoundingClientRect(); return { x: e.clientX - r.left, y: e.clientY - r.top } }

stage.addEventListener("mousedown", function(e) {
    if (e.button !== 0) return
    var p = local(e)
    if (!anim) drag = { x: p.x, y: p.y, s0: shape(), moved: false }
})
window.addEventListener("mousemove", function(e) {
    var p = local(e)
    if (drag) {
        var dx = p.x - drag.x
        if (!drag.moved && Math.abs(dx) > 5 && Math.abs(dx) > Math.abs(p.y - drag.y)) drag.moved = true
        if (drag.moved) {
            anim = null
            dragging = true
            stage.classList.add("dragging")
            // Dragging right unrolls the sigil into the strip.
            var s = S.clamp(drag.s0 - dx / 240, 0, 1)
            cur = S.RINGS.map(function() { return s })
            target = Math.round(s)
            buttons()
            return
        }
    }
    if (e.target !== stage && !stage.contains(e.target)) return
    if (lastLayout && machine) {
        var h = S.hit(lastLayout, { cur: cur }, p.x, p.y)
        if (h !== hi) { hi = h; showStatus(); dirty = true }
    }
})
window.addEventListener("mouseup", function() {
    var d = drag
    drag = null; dragging = false
    stage.classList.remove("dragging")
    if (!d) return
    if (d.moved) settle()
    else go(1 - target)
})
stage.addEventListener("mouseleave", function() { if (!drag && hi >= 0) { hi = -1; showStatus(); dirty = true } })

bSigil.addEventListener("click", function() { go(1) })
bStrip.addEventListener("click", function() { go(0) })
bSigil.addEventListener("mousedown", function(e) { e.stopPropagation() })
bStrip.addEventListener("mousedown", function(e) { e.stopPropagation() })
window.addEventListener("resize", function() { dirty = true })

// ------------------------------------------------------------ the app's side

// Opening starts from the sigil, the rings building in one by one.
function build() {
    builtAt = now(); building = true
    clearTimeout(buildTimer)
    buildTimer = setTimeout(function() { building = false }, 1100)
}

function take(m) {
    // A reading is taken only if it is not older than the one shown.
    if (machine && m.now < machine.now) return
    readAt = now()
    var first = !machine
    machine = m
    loadError = ""
    markCache = {}
    var gk = geoKey(m), sk = slowKey(m)
    if (!geo || geo.key !== gk || sk !== factsKey) {
        geo = S.geometry(m); geo.key = gk
        if (first || factsKey === "") build()
        factsKey = sk
    }
    header()
    refreshTexts(now())
    dirty = true
}

window.MachineMark = {
    take: take,
    // Memory, GPU load and uptime, every few seconds while open.
    live: function(v) {
        if (!machine || !v || !v.memory || v.now < machine.now) return
        var m = JSON.parse(JSON.stringify(machine))
        m.memory = v.memory; m.uptime = v.uptime; m.now = v.now
        if (v.gpu && v.gpu.usage !== undefined) m.gpu.usage = v.gpu.usage
        take(m)
    },
    setPalette: function(p) {
        pal = S.palette(p)
        var root = document.documentElement.style
        root.setProperty("--bg", pal.bg); root.setProperty("--fg", pal.fg)
        root.setProperty("--dim", pal.dim); root.setProperty("--accent", pal.accent)
        markCache = {}
        dirty = true
    },
    opened: function() {
        cur = S.RINGS.map(function() { return 1 })
        target = 1; anim = null; drag = null; dragging = false; hi = -1; say = ""
        buttons()
        build()
        running = true
        dirty = true
        showStatus()
    },
    resumed: function() { running = true; dirty = true },
    closed: function() { running = false },
    error: function(msg) { loadError = msg; loadingEl.textContent = msg; showStatus() }
}

document.getElementById("logo").textContent = ""
showStatus()
post({ type: "ready" })
// Opened in a plain browser (for working on the page): run with sample data.
if (!window.webkit) {
    running = true
    window.MachineMark.opened()
    fetch("sample.json").then(function(r) { return r.json() }).then(take).catch(function() {})
}
})()
