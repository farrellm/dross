import { describe, expect, it } from 'vitest'
import { clamp, toWorld, zoomAbout, MAX_K, MIN_K, type View } from './viewport'

/** The property every one of these tests is really about: whatever the reader
 *  does with two fingers, the world point that was under `from` ends up under
 *  `to`. */
function expectAnchored(view: View, from: { x: number; y: number }, to = from) {
  const before = toWorld(view, from.x, from.y)
  return {
    after(next: View) {
      const world = toWorld(next, to.x, to.y)
      expect(world.x).toBeCloseTo(before.x, 9)
      expect(world.y).toBeCloseTo(before.y, 9)
    },
  }
}

describe('zoomAbout', () => {
  it('keeps the world under an off-centre focal point in place', () => {
    // The bug this file exists for: zooming used to scale about the canvas
    // centre, shoving whatever you pinched on further off screen.
    const view: View = { x: 40, y: -25, k: 0.8 }
    const focal = { x: 180, y: -90 }
    const anchor = expectAnchored(view, focal)
    zoomAbout(view, focal, focal, 2)
    expect(view.k).toBeCloseTo(1.6, 9)
    anchor.after(view)
  })

  it('holds the anchor even when the zoom hits a stop', () => {
    // Clamping is why zoomAbout works from the ratio it applied and not the
    // one it was handed: pinching on against the stop must not creep.
    const view: View = { x: 12, y: 8, k: 3 }
    const focal = { x: -140, y: 60 }
    const anchor = expectAnchored(view, focal)
    zoomAbout(view, focal, focal, 10)
    expect(view.k).toBe(MAX_K)
    anchor.after(view)

    const out: View = { x: 12, y: 8, k: 0.25 }
    const held = expectAnchored(out, focal)
    zoomAbout(out, focal, focal, 0.01)
    expect(out.k).toBe(MIN_K)
    held.after(out)
  })

  it('is a pure pan when the fingers slide without spreading', () => {
    const view: View = { x: 5, y: -5, k: 1.4 }
    zoomAbout(view, { x: 10, y: 20 }, { x: 40, y: 5 }, 1)
    expect(view.k).toBeCloseTo(1.4, 9)
    expect(view.x).toBeCloseTo(35, 9)
    expect(view.y).toBeCloseTo(-20, 9)
  })

  it('follows a focal point that moves while it scales', () => {
    // A real pinch does both at once — the midpoint drifts as the span grows.
    const view: View = { x: -60, y: 30, k: 0.9 }
    const from = { x: 100, y: -40 }
    const to = { x: 130, y: -10 }
    const anchor = expectAnchored(view, from, to)
    zoomAbout(view, from, to, 1.35)
    expect(view.k).toBeCloseTo(1.215, 9)
    anchor.after(view)
  })

  it('leaves the view untouched for a no-op gesture', () => {
    const view: View = { x: 7, y: 11, k: 1 }
    zoomAbout(view, { x: 3, y: 4 }, { x: 3, y: 4 }, 1)
    expect(view).toEqual({ x: 7, y: 11, k: 1 })
  })
})

describe('toWorld', () => {
  it('inverts the canvas transform', () => {
    const view: View = { x: 25, y: -15, k: 2 }
    // screen = world * k + view
    expect(toWorld(view, 25, -15)).toEqual({ x: 0, y: 0 })
    expect(toWorld(view, 45, 5)).toEqual({ x: 10, y: 10 })
  })
})

describe('clamp', () => {
  it('bounds on both sides and passes the middle through', () => {
    expect(clamp(-3, MIN_K, MAX_K)).toBe(MIN_K)
    expect(clamp(99, MIN_K, MAX_K)).toBe(MAX_K)
    expect(clamp(1.5, MIN_K, MAX_K)).toBe(1.5)
  })
})
