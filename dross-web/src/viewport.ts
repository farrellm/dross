// The graph canvas's view transform, kept apart from the drawing so the
// gesture arithmetic can be reasoned about — and tested — on its own.
//
// Screen coordinates here are *canvas-centre-relative* CSS pixels, which is
// the frame `view.x`/`view.y` already live in: the canvas draws with
// `translate(view.x + w / 2, view.y + h / 2)` and then `scale(view.k)`, so
//
//     screen = world · k + view    (both measured from the canvas centre)
//
// Working in that frame is what makes the half-width term drop out of the
// zoom below.

export type View = { x: number; y: number; k: number }
export type Point = { x: number; y: number }

/** How far the reader may zoom out, and in. */
export const MIN_K = 0.2
export const MAX_K = 4

export function clamp(n: number, lo: number, hi: number): number {
  return Math.min(Math.max(n, lo), hi)
}

/** Screen → world, for hit testing. */
export function toWorld(view: View, x: number, y: number): Point {
  return { x: (x - view.x) / view.k, y: (y - view.y) / view.k }
}

/** Rescale by `ratio` about a focal point, and carry the view along if the
 *  focal point itself moved — so the world under the fingers stays under the
 *  fingers, and a pinch that slides doubles as a pan. Mutates the view in
 *  place: it is a ref, not state.
 *
 *  Solving `toWorld(view, from) = toWorld(view', to)` for the new offset
 *  gives `view' = to - (from - view) · r`, with the canvas centre cancelling.
 *  `r` is the ratio actually applied, not the one asked for: at the zoom
 *  stops those differ, and using the request would walk the anchor away
 *  a little on every frame the reader keeps pinching. */
export function zoomAbout(view: View, from: Point, to: Point, ratio: number): void {
  const k = clamp(view.k * ratio, MIN_K, MAX_K)
  const applied = k / view.k
  view.x = to.x - (from.x - view.x) * applied
  view.y = to.y - (from.y - view.y) * applied
  view.k = k
}
