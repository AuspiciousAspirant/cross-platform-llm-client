---
name: frontend-design
description: >-
  Anthropic's Frontend Design skill. Use this skill whenever designing, scaffolding,
  or refining user interfaces, web applications, landing pages, or components to ensure
  distinct visual identity, purposeful typography, custom color palettes, and strict
  anti-slop guidelines.
---

# Frontend Design Skill (Anthropic's UI/UX Standard)

This skill directs coding agents to think and act as lead visual and interaction designers. It prevents generic, template-driven "AI-slop" frontends (predictable indigo-purple gradients, generic 3-card feature rows, and cookie-cutter layouts) by requiring deliberate aesthetic planning before implementation.

---

## 1. Design Planning Before Code

Before writing UI code, formulate and declare a brief **Design Specification**:
1. **Vibe & Mood**: Define 2–3 mood words grounded in the project context (e.g., *Cyberpunk Command Center*, *Executive Minimalist*, *Warm Editorial*, *Technical Precision*).
2. **Color Palette Tokens**:
   - Backgrounds (primary, secondary, elevation/card surfaces)
   - Accents (high-contrast focal point colors)
   - Text hierarchy (primary high-contrast, secondary muted, metadata)
   - Semantic signals (success, warning, error, active)
3. **Typography Roles**: Distinct pairings with purpose (e.g., Mono for stats/system metadata, Display Sans or Serif for bold statements, clean Sans for body).
4. **Layout Composition**: Avoid the default centered 3-card layout. Use asymmetric grids, split-screen workflows, horizontal carousels, or multi-pane command layouts.

---

## 2. Anti-Slop & Anti-Default Rules

Never default to generic AI web patterns:
* **NO generic floating gradient blobs**: Replace with subtle border highlights, glassmorphism backdrop filters, or structured geometric containers.
* **NO uniform 3-card feature sections**: Vary card sizes, use spotlight hero units, split layouts, or interactive carousels.
* **NO unstyled inputs or controls**: All buttons, inputs, dropdowns, and toggles must have explicit hover, active, focus-visible, and disabled states.
* **NO washed-out low-contrast text**: Maintain WCAG AA accessibility standards. Body text must be crisp against dark or light surfaces.
* **NO predictable stock transitions**: Keep animations short (150ms–250ms), snappy, and purposeful (`cubic-bezier` or `ease-out`).

---

## 3. Visual Polish Checklist

* **Optical Padding**: Balance whitespace generously. Avoid cramped content inside card boundaries.
* **Microcopy**: Write active, contextual copy rather than placeholder boilerplate (e.g. "Connect Google Drive Vault" instead of "Click here").
* **Elevation & Borders**: Use subtle semi-transparent borders (`rgba(255, 255, 255, 0.08)` on dark, `rgba(0, 0, 0, 0.08)` on light) rather than harsh drop shadows.
* **Mobile Responsiveness**: Fluidly adapt multi-pane layouts into clean collapsible or stacked views on smaller viewports.

