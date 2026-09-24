# Design — Ordi (Terracotta Field, monochrome revision)

Locked design system, extracted from the approved "Terracotta Field" preview
(`design-preview/04-terracotta-field.html`). Hand this file to a UI-generation
tool as the system to build within — colors, type, spacing, radii, motion and
component voice are all fixed; only layout and content should vary per screen.

## System
- Genre · playful, revised to pure black/white/gray
- Macrostructure · native-app tactile-card stack — flat list screens (History,
  Recordings, Study chapters) drill into detail screens with a back chevron;
  the Home dashboard's action row is a 2-up/1-down grid, not a plain list
- Theme · custom (vibe: "quiet, tactile, monochrome — no brand hue")
- Axes · paper-band: light · display-style: humanist-serif · accent-hue: none
  (pure black/white; red and green exist only as status signals, not a brand accent)

## Tokens
```css
:root {
  --color-paper:       #FFFFFF;  /* app background */
  --color-paper-2:     #F4F4F4;  /* card / tile fill */
  --color-rule:        #E2E2E2;  /* hairline border, strong */
  --color-rule-soft:   #ECECEC;  /* hairline border, quiet */
  --color-ink:         #111111;  /* primary text, icons, all "accent" fills */
  --color-ink-soft:    #4A4A4A;  /* secondary text (summaries, meta) */
  --color-ink-faint:   #8A8A8A;  /* tertiary text (timestamps, empty states) */
  --color-accent:      var(--color-ink);   /* every "selected/primary" fill is solid black */
  --color-accent-ink:  #FFFFFF;            /* text/icon color ON the accent */
  --color-focus:       var(--color-ink);   /* focus ring */

  /* Status only — never used decoratively, never for headings or brand moments */
  --color-good:        #348F4F;  /* "connected" dot */
  --color-danger:      #C8393A;  /* "recording" dot, delete, destructive text */

  --font-display: "Fraunces", ui-serif, Georgia, serif;         /* headings, titles */
  --font-body:    "Plus Jakarta Sans", ui-sans-serif, system-ui, sans-serif; /* everything else */
  --font-mono:    "Space Mono", ui-monospace, monospace;        /* labels, timestamps, counts */

  /* Spacing — 4pt-family, observed scale: 4 · 6 · 8 · 10 · 12 · 14 · 16 · 18 · 20 · 24 */
  /* Radii: 14–16px icon badges · 20–22px cards · 32px outer container · 999px pills/circles */

  --ease-out: cubic-bezier(0.16, 1, 0.3, 1);
  --dur-fast: 120ms;   /* screen transitions — kept short and shallow, see Motion */
  --dur-base: 180ms;   /* press states, checkbox fill */
  --dur-slow: 220ms;   /* segmented-control thumb slide */
}
```

**Native mapping.** This is a Flutter/iOS app, not a web page — read the
tokens above as the system, not literally as CSS. `--color-*` → Flutter
`Color`/SwiftUI `Color` constants; `--font-display`/`--font-body` → the
nearest system-installed equivalents if Fraunces/Plus Jakarta Sans/Space Mono
aren't bundled (SF Pro + a serif fallback is acceptable, but keep the
display/body/mono *role* split — don't collapse to one face); spacing/radii
map directly to `EdgeInsets`/`BorderRadius` in the same pixel values.

## Component voice
- **Cards/tiles** · flat fill `--color-paper-2` on `--color-paper`, no
  shadow, no border, 20–22px radius. No glass/blur anywhere in this system.
- **Primary action (checked box, active segment, FAB, Save button)** · solid
  `--color-ink` fill, `--color-accent-ink` (white) content, pill or circle
  radius.
- **Icon-only buttons** · always `display:flex; align-items:center;
  justify-content:center` on the button itself — never rely on the browser/
  platform's default text centering for a glyph. (This was the one bug class
  found repeatedly during review: a bare icon button left un-centered.)
- **Screen-to-screen navigation** · 120ms fade-and-settle, never a full
  opacity-from-zero fade (reads as "flickering/washed out" on fast taps,
  confirmed by testing). If an element needs `position:fixed`-like behavior
  (a floating action button), anchor it with `position:relative` on the
  screen + `position:absolute` on the element — not `position:fixed` — since
  any ancestor with an animated `transform` silently breaks `fixed`.
- **List rows** · title + right-aligned chevron, `align-items:center` (not
  `baseline` — baseline visibly misaligns a heading against a small glyph).

## Motion stance
- Default-on, but light: press-scale on every tappable surface (0.97–0.98),
  a checkbox pop-in, a sliding segmented-control thumb. No page-load stagger,
  no scroll-triggered animation.
- Reduced-motion fallback: all animations either skip or drop to a single
  short opacity step.

## Notes for the next design pass
- The palette was deliberately taken from a warm terracotta accent down to
  pure black/white — if a future pass wants color back, reintroduce it as
  ONE accent hue only, and keep it off headings/body text (put it on
  active-state fills and small status marks only, the same restraint this
  system already applies to red/green).
- Real content only — the shipped preview uses actual task/recording/session
  text, not lorem ipsum; keep that standard for anything generated from this
  file.

## Exports
This file is the source of truth; no separate `tokens.css` exists for this
project. If a UI-generation tool needs Tailwind `@theme`, a DTCG
`tokens.json`, or shadcn/ui CSS variables, ask for that specific format and
it can be appended here.
