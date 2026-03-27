# App Design Brief — mfree (working title)
*Written from the designer's chair*

---

## The one thing to never forget

The person using this app just had a baby. They are running on 3 hours of sleep. Their hands are full — literally. Their nervous system is on high alert.

Every design decision must answer: **can an exhausted parent use this correctly, in the dark, one-handed, in under 5 seconds?**

If no → redesign it.

---

## Design Principles

### 1. Calm over clever
No animations that demand attention. No badges screaming for action. The app should feel like a quiet, reliable presence — like a night light, not a notification.

### 2. Glanceable first, detail on demand
The home screen should answer "is everything okay?" in one glance. Details live one tap deeper. Never show a wall of text on the primary view.

### 3. One-handed always
Every primary action reachable with a thumb. Bottom-anchored navigation. No critical buttons at the top of the screen. Large tap targets (min 44×44pt, prefer 56×56pt for nighttime).

### 4. Dark mode is the default
Parents use this at 3am with a sleeping baby next to them. Dark mode isn't a nice-to-have — it's the primary experience. Light mode is the variant.

### 5. Warm, not clinical
This app is about a baby, not a patient. Soft typography, warm neutrals, no cold blues or sterile whites. Data displayed with care, not as a dashboard.

---

## Color System

### Dark mode (primary)
```
Background          #0E0E10   Near black, warm undertone
Surface             #1C1C1E   Card background (iOS system grouped)
Surface raised      #2C2C2E   Elevated cards, sheets
Border              #3A3A3C   Subtle dividers

Text primary        #F2F2F7   Warm white
Text secondary      #8E8E93   Muted labels
Text tertiary       #48484A   Disabled / placeholder

Accent              #FF9F43   Warm amber — primary CTAs, highlights
Accent soft         #FF9F4320 Amber tint for backgrounds
Success             #30D158   Green — normal ranges, good stats
Warning             #FFD60A   Yellow — mild flags, watch items
Alert               #FF453A   Red — urgent flags only (fever in newborn, etc.)
Milestone gold      #FFD700   ✨ moments, milestones, firsts
```

### Light mode
```
Background          #F2F2F7
Surface             #FFFFFF
Surface raised      #F2F2F7
Accent              #E8820C   Slightly deeper amber for contrast
```

### Usage rule
Use **amber** for the main brand color — it's warm, energetic without being alarming, and reads as "attentive" not "urgent". Reserve red strictly for health alerts. Never use red for empty states or missing data.

---

## Typography

Use SF Pro (system font). Don't fight iOS — this is a utility app, not an editorial experience.

```
Display             SF Pro Rounded, 34pt, weight: semibold
                    → Day summary headline, milestone moments

Title 1             SF Pro, 28pt, weight: bold
                    → Screen titles

Title 2             SF Pro, 22pt, weight: semibold
                    → Section headers inside cards

Body                SF Pro, 17pt, weight: regular
                    → Standard body text, event descriptions

Body emphasis       SF Pro, 17pt, weight: medium
                    → Key values (feed amounts, durations)

Caption             SF Pro, 13pt, weight: regular, color: secondary
                    → Timestamps, secondary metadata

Mono stat           SF Mono, 22pt, weight: semibold
                    → Numbers in stats bar (feeds, hours, diapers)
                    → Monospaced so numbers don't shift width
```

**Use SF Pro Rounded for anything baby-related** (names, milestone text, summary sentence). It reads warmer than standard SF Pro without being childish.

---

## Key Screens

### 1. Home — Monitor Screen

**Purpose**: Is the app listening? Did anything happen recently?

**Layout:**
```
┌─────────────────────────────────┐
│  Good evening, Oliver 🌙        │  ← greeting, baby name, time context
│  6 months, 12 days              │  ← exact age (matters for milestones)
│                                 │
│  ┌─────────────────────────┐    │
│  │  🎙  Listening...        │    │  ← large status card, pulsing when active
│  │  Last event: 12 min ago  │    │
│  └─────────────────────────┘    │
│                                 │
│  Today so far                   │
│  ┌──────┐ ┌──────┐ ┌──────┐    │
│  │ 🍼 6 │ │ 😴 9h│ │ 💧 7 │    │  ← quick stats, tap to jump to section
│  └──────┘ └──────┘ └──────┘    │
│                                 │
│  Recent events                  │
│  ──────────────────────────     │
│  2:41 pm  Fed — bottle, 4 oz   │
│  1:15 pm  Nap ended — 1h 20m   │
│  11:30 am ✨ First word attempt │
│                                 │
│  [Hold to add a note]           │  ← hold-to-record button, thumb reach
└─────────────────────────────────┘
```

**Design notes:**
- The listening status card is the hero element — big, clear, impossible to miss
- Stats bar is glanceable — 3 numbers max on this screen
- Recent events list: max 5 items, newest first, no scrolling required
- Hold-to-record button is bottom-center, large, 80px diameter

---

### 2. Daily Report Screen

Follows the structure in `daily-report-design.md`. Design additions:

**Card hierarchy:**
- Each section (Feeding, Sleep, Diapers, Health, Milestones) is a card
- Cards collapsed by default on first open — show summary line only
- Tap card to expand full detail
- Cards with flags show a colored left border (amber = watch, red = urgent)

**Milestone card treatment:**
- Full-width, slightly warmer background (#2A2215 in dark mode)
- Gold accent color
- Larger text, more breathing room
- Screenshot-worthy — this is the one parents will share

**Stats row:**
```
  ┌────────────────────────────────────────┐
  │  🍼 7     😴 13.5h    💧 8    💩 3     │
  └────────────────────────────────────────┘
```
Numbers in SF Mono so they don't jitter as values change.

---

### 3. Event Log Screen

Full timeline of the day. Think: a calm logbook, not a data grid.

- Left-aligned timeline with time column (right-aligned timestamps)
- Event type shown as an icon + label, not just text
- Swipe left to edit/delete an event
- AI-generated events shown with a subtle `AI` badge — parent can correct them
- Corrections shown with a strikethrough + replacement (builds trust in the AI)

---

### 4. Summary / Week View

- Horizontal scroll through the last 7 days
- Each day: one-line AI summary + 3 key stats
- Tap a day to go to its full report
- Trend line for sleep total across the week (sparkline, not a full chart)
- Milestone count for the week highlighted at top

---

### 5. Hold-to-Record Sheet (Voice Note / Correction)

Appears when parent holds the button. Two modes — keep them visually distinct:

**Log mode** (default): amber border, microphone icon
> "Say what happened and I'll log it."

**Support mode** (tap to switch): soft purple border, chat bubble icon
> "Tell me what's going on. I'm listening."

Large waveform visualization while recording — gives feedback that audio is being captured. Waveform color matches the mode (amber / purple).

---

## Navigation

Use a tab bar with 4 items — no more:

```
[Home]  [Today]  [Report]  [Settings]
```

- **Home** = Monitor (is it listening, recent events)
- **Today** = Full event log for today
- **Report** = Daily report / weekly summary
- **Settings** = Baby profile, speaker setup, preferences

Keep it at 4. Don't add tabs for features that could live inside existing tabs.

---

## Empty States

Never show a blank screen. Every empty state needs:
1. A warm illustration or large emoji (not a sad face — a sleepy one is fine)
2. One sentence explaining why it's empty
3. One action to take

Examples:
```
No events yet today
The app is listening. Events will appear here when it detects
something — or you can add one yourself.
[+ Add manually]
```

```
No report yet
Reports are ready each evening around 8pm.
[See yesterday's report]
```

---

## Interactions & Motion

- **Keep motion minimal** — parents are overstimulated. No bouncy springs, no dramatic transitions.
- Use iOS default push/modal transitions — don't fight the system.
- The listening pulse animation: slow, 3-second cycle, low opacity change (0.6 → 1.0). Like breathing.
- Card expansion: simple height animation, 200ms ease-out. No flips, no 3D.
- Milestone card: a single soft glow on appear (one-shot, not looping).

---

## Accessibility

- All text meets WCAG AA contrast in both modes (critical for 3am dark room use)
- All touch targets min 44×44pt
- VoiceOver labels on all icons and stat values
- Reduce Motion: disable all animations, use instant transitions
- Dynamic Type: test at XXL size — parents with tired eyes may bump up text

---

## What NOT to design

- **No gamification** — no streaks, points, badges for logging. This isn't Duolingo.
- **No social features** — parents don't want to share their baby's data with strangers.
- **No complexity theater** — no "advanced analytics", no confusing charts. Simple numbers.
- **No dark patterns** — no upsell banners inside the active monitoring screen. Never interrupt a listening session with a notification.
- **No red unless it's real** — reserve red/alert colors for genuinely urgent situations only. Crying wolf trains parents to ignore them.

---

## Open Design Questions

1. **Onboarding**: How do we introduce the AI + audio permissions without being scary? First-run should feel like meeting a helpful friend, not agreeing to a terms of service.

2. **Multiple babies**: Does the design need to support twins or baby #2 from day one? (Tab bar baby switcher? Or scope to one baby for v1?)

3. **Caregiver handoff**: Can a nanny or grandparent see a read-only view? What does that sharing flow look like?

4. **Report delivery**: Push notification at 8pm "Oliver's daily report is ready" — what does the notification preview show? Should be the one-line summary.

5. **App icon**: Should feel warm, not clinical. A simple cradle? A soft ✨? A stylized letter once we land on the final name?
