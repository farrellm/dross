// Shape says what kind of thing a node is; the temper ramp (temper.ts) says
// how far away it is. Two channels, two meanings, never crossed — a note's
// kind must never reach for a colour, and a distance must never reach for a
// shape.
//
// One marked case only. A literature note is a note *on a source*, which is
// structurally a different animal from an atomic idea; everything else — a
// permanent note, an untagged one, a headline, a link with no note behind it
// — is just a note, and keeps the circle.

export type Kind = 'literature' | 'note'

/** Note kind from its filetags. Headline nodes inherit the file's tags when
 *  they are indexed, so a headline inside a literature note counts too. */
export function noteKind(tags?: string[]): Kind {
  return tags?.includes('literature') ? 'literature' : 'note'
}
