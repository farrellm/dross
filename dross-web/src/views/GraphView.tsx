import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import {
  forceCenter,
  forceCollide,
  forceLink,
  forceManyBody,
  forceSimulation,
  forceX,
  forceY,
  type Simulation,
  type SimulationLinkDatum,
  type SimulationNodeDatum,
} from 'd3-force'
import { api, type Graph } from '../api'
import { useAsync } from '../useAsync'
import { Empty, Failed, Loading } from '../components/bits'
import { bandColor, hopBand } from '../temper'
import { noteKind, type Kind } from '../kind'
import { clamp, toWorld, zoomAbout, MIN_K } from '../viewport'

type Node = SimulationNodeDatum & {
  id: string
  label: string
  kind: Kind
  distance: number | null
  dangling: boolean
}
type Edge = SimulationLinkDatum<Node>

const TAP_SLOP = 8 // px of movement still counted as a tap, not a drag
const HIT_RADIUS = 22

export function GraphView() {
  const [params, setParams] = useSearchParams()
  const focus = params.get('focus')
  const depth = clamp(Number(params.get('depth')) || 2, 1, 3)

  const graph = useAsync(
    (signal) => (focus ? api.neighborhood(focus, depth, signal) : api.graph(signal)),
    [focus, depth],
  )

  const setFocus = (next: string | null) => {
    const p = new URLSearchParams()
    if (next) p.set('focus', next)
    setParams(p, { replace: true })
  }

  return (
    <div className="graphview">
      <header className="head">
        <p className="eyebrow">{focus ? 'Around one note' : 'The whole collection'}</p>
        <div className="head-row">
          <div className="segmented" role="group" aria-label="What to show">
            <button type="button" aria-pressed={!focus} onClick={() => setFocus(null)}>
              Everything
            </button>
            <button
              type="button"
              aria-pressed={!!focus}
              disabled={!focus}
              onClick={() => setFocus(focus)}
            >
              This note
            </button>
          </div>
          {focus && (
            <label className="depth">
              Depth
              <input
                type="range"
                min={1}
                max={3}
                value={depth}
                onChange={(e) => {
                  const p = new URLSearchParams(params)
                  p.set('depth', e.target.value)
                  setParams(p, { replace: true })
                }}
              />
              <span className="depth-value">{depth}</span>
            </label>
          )}
        </div>
      </header>

      {graph.state === 'loading' && <Loading what="the graph" />}
      {graph.state === 'failed' && <Failed error={graph.error} />}
      {graph.state === 'ready' &&
        (graph.value.nodes.length === 0 ? (
          <Empty>
            {focus
              ? 'This note has no links yet.'
              : 'No notes are linked yet. Links are what make the graph.'}
          </Empty>
        ) : (
          <>
            <Canvas graph={graph.value} focus={focus} />
            <Legend
              focused={!!focus}
              sources={graph.value.nodes.some((n) => noteKind(n.tags) === 'literature')}
            />
          </>
        ))}
    </div>
  )
}

function Legend({ focused, sources }: { focused: boolean; sources: boolean }) {
  return (
    <p className="legend">
      {focused
        ? [1, 2, 3].map((d) => (
            <span key={d} className="legend-item">
              <span className="pip" style={{ background: bandColor(hopBand(d)) }} />
              {d} hop{d > 1 ? 's' : ''}
            </span>
          ))
        : 'Tap a note to open it. Drag to pan, pinch to zoom.'}
      {/* The kind key earns its line only when a source is on screen. Its
          pips take a neutral, off the ramp: shape is the claim here, and a
          band colour would read as a distance. */}
      {sources && (
        <>
          <span className="legend-item">
            <span className="pip pip-square" style={{ background: 'var(--ink-dim)' }} />
            source
          </span>
          <span className="legend-item">
            <span className="pip" style={{ background: 'var(--ink-dim)' }} />
            note
          </span>
        </>
      )}
    </p>
  )
}

function Canvas({ graph, focus }: { graph: Graph; focus: string | null }) {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const navigate = useNavigate()
  const view = useRef({ x: 0, y: 0, k: 1 })
  // The force layout lays out in its own coordinates — hundreds of px
  // across even for a small graph — so the view frames it until the reader
  // takes over by panning or zooming.
  const autoFit = useRef(true)
  const [, force] = useState(0)

  const { nodes, edges } = useMemo(() => {
    const nodes: Node[] = graph.nodes.map((n) => ({
      id: n.id,
      label: n.title ?? 'untitled',
      kind: noteKind(n.tags),
      distance: n.distance ?? null,
      dangling: n.title === null,
    }))
    const byId = new Map(nodes.map((n) => [n.id, n]))
    const edges: Edge[] = graph.edges.flatMap((e) => {
      const source = byId.get(e.from)
      const target = byId.get(e.to)
      return source && target ? [{ source, target }] : []
    })
    return { nodes, edges }
  }, [graph])

  const draw = useCallback(() => {
    const canvas = canvasRef.current
    const ctx = canvas?.getContext('2d')
    if (!canvas || !ctx) return

    const dpr = window.devicePixelRatio || 1
    const w = canvas.clientWidth
    const h = canvas.clientHeight
    if (canvas.width !== w * dpr || canvas.height !== h * dpr) {
      canvas.width = w * dpr
      canvas.height = h * dpr
    }
    // Canvas takes colours and fonts as values, not `var(--x)`: assigning
    // one silently leaves the previous value in place, so resolve first.
    const style = getComputedStyle(canvas)
    const cssVar = (name: string) => style.getPropertyValue(name).trim()
    const ink = cssVar('--ink')
    const dim = cssVar('--ink-faint')
    const rule = cssVar('--rule')
    const ramp = [1, 2, 3, 4, 5].map((i) => cssVar(`--t${i}`) || '#888')

    if (autoFit.current) fit(nodes, view.current, w, h)

    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    ctx.clearRect(0, 0, w, h)
    ctx.translate(view.current.x + w / 2, view.current.y + h / 2)
    ctx.scale(view.current.k, view.current.k)

    ctx.strokeStyle = rule
    ctx.lineWidth = 1 / view.current.k
    ctx.beginPath()
    for (const e of edges) {
      const s = e.source as Node
      const t = e.target as Node
      if (s.x === undefined || t.x === undefined) continue
      ctx.moveTo(s.x, s.y ?? 0)
      ctx.lineTo(t.x, t.y ?? 0)
    }
    ctx.stroke()

    // Labels are 11px on screen whatever the zoom, so past a couple of
    // dozen nodes they pile up: make the reader zoom in for names.
    const labelled = nodes.length <= 24 || view.current.k > 1.2
    ctx.font = `500 ${11 / view.current.k}px ${cssVar('--mono') || 'monospace'}`
    ctx.textAlign = 'center'
    ctx.textBaseline = 'top'

    for (const n of nodes) {
      if (n.x === undefined || n.y === undefined) continue
      const isFocus = n.id === focus
      // Radii in screen pixels, like the line widths: a zoomed-out graph
      // still has nodes you can see and hit.
      const r = (isFocus ? 9 : n.dangling ? 4 : 6) / view.current.k
      ctx.beginPath()
      // A dangling target has no note behind it and so no kind: it keeps the
      // circle, and the smaller radius is what marks it.
      mark(ctx, n.dangling ? 'note' : n.kind, n.x, n.y, r)
      // With no root there is no distance to show, so the whole-collection
      // graph sits at the cold end of the ramp rather than on it.
      ctx.fillStyle = n.dangling
        ? rule
        : n.distance === null
          ? (ramp[4] ?? dim)
          : (ramp[hopBand(n.distance === 0 ? 1 : n.distance) - 1] ?? dim)
      ctx.fill()
      if (isFocus) {
        ctx.strokeStyle = ink
        ctx.lineWidth = 2 / view.current.k
        ctx.stroke()
      }
      if (labelled) {
        ctx.fillStyle = isFocus ? ink : dim
        ctx.fillText(truncate(n.label), n.x, n.y + r + 3 / view.current.k)
      }
    }
  }, [nodes, edges, focus])

  useEffect(() => {
    // A different graph deserves a fresh frame.
    autoFit.current = true
    const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches
    const sim: Simulation<Node, Edge> = forceSimulation(nodes)
      .force('link', forceLink<Node, Edge>(edges).id((d) => d.id).distance(46).strength(0.6))
      .force('charge', forceManyBody().strength(nodes.length > 80 ? -90 : -160))
      .force('center', forceCenter(0, 0))
      // A collection is several disconnected clusters, and charge alone
      // flings them apart until the fit has to zoom out past readability.
      // A weak pull toward each axis packs them into one frame — stronger
      // horizontally, so the cloud comes out portrait like the screen and
      // the fit does not leave half the canvas empty.
      .force('x', forceX(0).strength(0.1))
      .force('y', forceY(0).strength(0.035))
      .force('collide', forceCollide(16))

    if (reduced) {
      // Settle off-screen and paint the result once.
      sim.stop()
      sim.tick(300)
      draw()
    } else {
      sim.on('tick', draw)
    }
    return () => {
      sim.stop()
    }
  }, [nodes, edges, draw])

  useEffect(() => {
    const observer = new ResizeObserver(() => {
      draw()
      force((n) => n + 1)
    })
    if (canvasRef.current) observer.observe(canvasRef.current)
    return () => observer.disconnect()
  }, [draw])

  // Pan, pinch, and tap. Pointer events cover touch and mouse alike.
  const gesture = useRef({
    pointers: new Map<number, { x: number; y: number }>(),
    moved: 0,
    // Span and midpoint of the two fingers, or null when fewer than two are
    // down. The midpoint is what a pinch zooms about, so it has to be
    // remembered frame to frame alongside the span.
    pinch: null as null | { span: number; x: number; y: number },
  })

  /** Where the fingers are, in the canvas-centre-relative pixels the view
   *  transform speaks (see viewport.ts). Null with fewer than two down. */
  const pinchState = (canvas: HTMLCanvasElement) => {
    const [a, b] = [...gesture.current.pointers.values()]
    if (!a || !b) return null
    const rect = canvas.getBoundingClientRect()
    return {
      span: Math.hypot(a.x - b.x, a.y - b.y),
      x: (a.x + b.x) / 2 - rect.left - rect.width / 2,
      y: (a.y + b.y) / 2 - rect.top - rect.height / 2,
    }
  }

  /** Cursor position in the same frame, for wheel zoom. */
  const focalPoint = (canvas: HTMLCanvasElement, clientX: number, clientY: number) => {
    const rect = canvas.getBoundingClientRect()
    return { x: clientX - rect.left - rect.width / 2, y: clientY - rect.top - rect.height / 2 }
  }

  const onDown = (e: React.PointerEvent<HTMLCanvasElement>) => {
    e.currentTarget.setPointerCapture(e.pointerId)
    gesture.current.pointers.set(e.pointerId, { x: e.clientX, y: e.clientY })
    gesture.current.moved = 0
    // Seed on the way in, so the first two-finger move already zooms.
    if (gesture.current.pointers.size >= 2) {
      gesture.current.pinch = pinchState(e.currentTarget)
    }
  }

  const onMove = (e: React.PointerEvent<HTMLCanvasElement>) => {
    const g = gesture.current
    const prev = g.pointers.get(e.pointerId)
    if (!prev) return
    g.pointers.set(e.pointerId, { x: e.clientX, y: e.clientY })

    autoFit.current = false
    if (g.pointers.size >= 2) {
      const next = pinchState(e.currentTarget)
      // Zooming about the midpoint, and following the midpoint as it slides,
      // is one call: a pinch that drifts pans as well, which is what the hand
      // expects it to do.
      if (next && g.pinch && g.pinch.span > 0 && next.span > 0) {
        zoomAbout(view.current, g.pinch, next, next.span / g.pinch.span)
      }
      g.pinch = next
      g.moved += TAP_SLOP + 1
    } else {
      view.current.x += e.clientX - prev.x
      view.current.y += e.clientY - prev.y
      g.moved += Math.abs(e.clientX - prev.x) + Math.abs(e.clientY - prev.y)
    }
    draw()
  }

  const onUp = (e: React.PointerEvent<HTMLCanvasElement>) => {
    const g = gesture.current
    g.pointers.delete(e.pointerId)
    // Re-seed rather than blank: lifting one of three fingers should carry on
    // pinching with the two that remain.
    g.pinch = g.pointers.size >= 2 ? pinchState(e.currentTarget) : null
    if (g.moved > TAP_SLOP) return

    const canvas = e.currentTarget
    const focal = focalPoint(canvas, e.clientX, e.clientY)
    const { x, y } = toWorld(view.current, focal.x, focal.y)

    let best: Node | null = null
    let bestDistance = HIT_RADIUS / view.current.k
    for (const n of nodes) {
      if (n.x === undefined || n.y === undefined) continue
      const d = Math.hypot(n.x - x, n.y - y)
      if (d < bestDistance) {
        best = n
        bestDistance = d
      }
    }
    if (best && !best.dangling) navigate(`/note/${encodeURIComponent(best.id)}`)
  }

  return (
    <canvas
      ref={canvasRef}
      className="graph"
      onPointerDown={onDown}
      onPointerMove={onMove}
      onPointerUp={onUp}
      onPointerCancel={onUp}
      onWheel={(e) => {
        autoFit.current = false
        // Zoom about the cursor, as the pinch does about the fingers.
        const focal = focalPoint(e.currentTarget, e.clientX, e.clientY)
        zoomAbout(view.current, focal, focal, e.deltaY < 0 ? 1.1 : 0.9)
        draw()
      }}
    />
  )
}

/** Frame every node with a margin, capped so a two-node graph does not
 *  balloon. Mutates the view in place — it is a ref, not state. */
function fit(nodes: Node[], view: { x: number; y: number; k: number }, w: number, h: number) {
  let minX = Infinity
  let minY = Infinity
  let maxX = -Infinity
  let maxY = -Infinity
  for (const n of nodes) {
    if (n.x === undefined || n.y === undefined) continue
    minX = Math.min(minX, n.x)
    maxX = Math.max(maxX, n.x)
    minY = Math.min(minY, n.y)
    maxY = Math.max(maxY, n.y)
  }
  if (!Number.isFinite(minX)) return

  const margin = 48 // room for the labels hanging below each node
  const k = clamp(
    Math.min((w - margin) / Math.max(maxX - minX, 1), (h - margin) / Math.max(maxY - minY, 1)),
    MIN_K,
    1.6,
  )
  view.k = k
  view.x = (-(minX + maxX) / 2) * k
  view.y = (-(minY + maxY) / 2) * k
}

/** Trace a node's mark on the current path: a square for a literature note,
 *  a circle for everything else. Colour is the ramp's job, so shape is what
 *  is left to say what kind of thing this is. The square is scaled to the
 *  circle's area (side 2r·√π/2) rather than its diameter — matched by weight,
 *  since radius here already means focus and dangling. */
function mark(ctx: CanvasRenderingContext2D, kind: Kind, x: number, y: number, r: number) {
  if (kind === 'literature') {
    const half = r * 0.886
    ctx.rect(x - half, y - half, half * 2, half * 2)
  } else {
    ctx.arc(x, y, r, 0, Math.PI * 2)
  }
}

function truncate(label: string): string {
  return label.length > 22 ? label.slice(0, 21) + '…' : label
}
