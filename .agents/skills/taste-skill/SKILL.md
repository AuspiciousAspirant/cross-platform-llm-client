---
name: taste-skill
description: >-
  The "With Taste" frontend framework (taste-skill). Use this skill when building
  websites, apps, or design components to enforce taste, strong art direction,
  layout variance, and strict anti-slop frontend rules across all major UI archetypes.
---

# Taste Skill: The Anti-Slop Frontend Framework

Taste is the antidote to AI-generated sameness. This framework forces the agent to make opinionated, coherent, and tasteful design decisions tailored to the product's identity.

---

## 1. Choose a Design Archetype

Before generating markup or styles, determine which visual archetype fits the project:

### A. Technical & Command (Default for Developer/Terminal/Dashboard Apps)
* **Aesthetic**: Jet black and dark slate, monospaced accents, neon edge glows (cyan, emerald, violet), glassmorphism panes, dense information hierarchy.
* **Typography**: Mono tags (`JetBrains Mono`, `Fira Code`) + modern grotesk sans (`Inter`, `Geist`).
* **Borders**: Crisp 1px subtle lines (`rgba(255, 255, 255, 0.08)`), glowing status dots, live indicators.

### B. Minimalist & Editorial
* **Aesthetic**: Vast whitespace, deliberate restraint, high typographic contrast, warm off-white or charcoal surfaces, minimal decorative elements.
* **Typography**: Serif or high-contrast display headlines + neutral geometric body.
* **Interactions**: Subtle opacity transitions, generous line-heights, underline hover states.

### C. Brutalist / Neo-Brutalist
* **Aesthetic**: High contrast, heavy black borders (`2px - 3px solid #000`), hard offset drop shadows (`4px 4px 0 #000`), bold saturated color blocks.
* **Typography**: Bold grotesque sans-serifs, all-caps category tags.

### D. Soft & Tactile
* **Aesthetic**: Smooth radiuses (`rounded-2xl`), deep layered blur effects, soft tonal shifts rather than harsh lines, tactile button depression.

---

## 2. The Strict Anti-Slop Ban List

1. **NO Default "SaaS Purple"**: Banned: `#6366f1` / `#8b5cf6` linear gradient text over generic dark backgrounds unless explicitly requested.
2. **NO Repetitive Feature Grids**: Do not generate 3 identical rectangular boxes with an icon on top, a generic title, and two lines of filler text. Use asymmetrical layouts, spotlights, or interactive tabbed components.
3. **NO Decorative Floating Blobs**: Do not place large blurred circles in the background that add zero functional or contextual value.
4. **NO Dead Interactions**: Every interactive element (buttons, cards, links, tabs) must have a noticeable, pleasing hover and active state.
5. **NO Unformatted Lists**: Never render raw bullets when tags, cards, or timeline nodes can represent the information with structure.

---

## 3. Spatial Discipline & Layout Rules

* **Density**: Match layout density to purpose: high-density for dashboards and tools (compact padding, clear dividers), low-density for marketing and portfolio showcases (generous breathing room).
* **Grid Hierarchy**: Always have a clear visual "hero" element on the page that immediately anchors the viewer's eye before secondary content.
* **Click-Through & Exploration**: For portfolios and showcases, prefer interactive click-throughs, sliders, or modal inspectors over flat walls of text.

