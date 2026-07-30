// The tempering ramp. Five bands, one meaning: how far this is from where
// you are. Anything that is not a distance stays off the ramp.

export type Band = 1 | 2 | 3 | 4 | 5

export const bandColor = (b: Band) => `var(--t${b})`

/** Hops from the note you are reading. Band 1 is adjacent. */
export function hopBand(distance: number): Band {
  return Math.min(Math.max(distance, 1), 5) as Band
}

/** Cosine similarity in [0,1]. Cut points are where the collection's own
 *  scores separate real neighbours from noise — the bot uses 0.5 for the
 *  same job (nudgeThreshold in main.go). */
export function scoreBand(score: number): Band {
  if (score >= 0.75) return 1
  if (score >= 0.65) return 2
  if (score >= 0.55) return 3
  if (score >= 0.45) return 4
  return 5
}

/** Full-text results have no score, so they take their band from rank. */
export function rankBand(index: number): Band {
  return hopBand(Math.floor(index / 3) + 1)
}
