# Project Operational Guidelines & Tool Usage Rules (2026 Edition)

This file defines always-active workspace rules for AI agents operating on the **Cross-Platform Distributed LLM Client (PrivateLM)** repository. Follow these directives across all tasks.

---

## 1. Design & Visual Standards (Anti-Slop Framework)

* **Design Aesthetic**:
  - Purposeful visual identity adhering to modern high-craft design (refer to `taste-skill` and `frontend-design`).
  - **Surfaces & Hierarchy**: Crisp, high-contrast typography, refined surface elevations, and subtle hairline borders (`rgba(255, 255, 255, 0.08)` or clean neutral borders).
  - **Anti-Slop Directives**: NO generic floating gradient blobs, NO generic saas-purple linear gradient text overlays, and NO repetitive identical 3-card feature grids.
  - **Desktop Responsiveness**: On desktop viewports (width >= 800px), always utilize the collapsible sidebar navigation rail, docked split-pane chat history, and center-constrained reading bubbles (`maxWidth: 860px`).
  - **Interactive States**: Ensure every interactive component (buttons, inputs, dropdowns, cards) features polished hover, active, focus-visible, and disabled states.

---

## 2. Proactive Tool & MCP Server Usage

Always invoke available MCP servers and tools proactively rather than relying on guesswork:

* **Playwright MCP (`dev-toolkit_playwright`)**:
  - Whenever working on frontend components, layouts, or bug fixes, **visually verify the results** using `browser_navigate`, `browser_snapshot`, and `browser_take_screenshot`.
  - Open the page, test user flows, and inspect actual rendering across viewport sizes.

* **Context7 MCP (`dev-toolkit_context7`)**:
  - Use `resolve-library-id` and `query-docs` whenever interacting with external libraries or new APIs to retrieve up-to-date documentation and TypeScript/Dart definitions.

* **Firecrawl MCP (`dev-toolkit_firecrawl`)**:
  - Proactively use for deep web queries, scraping documentation, external research, or API investigations.

* **Database & Cloud MCPs (`dev-toolkit_supabase`, `dev-toolkit_vercel`, etc.)**:
  - Leverage configured servers when deploying, querying database schemas, or managing cloud workflows.

---

## 3. Subagent Delegation Protocol (2026 Agentic Standard)

To maintain context efficiency and prevent context compaction during large tasks:
* **Deploy `research` Subagents**:
  - For broad codebase scans, multi-file traces, third-party API reverse-engineering, or bundle analysis. Offloading exploration keeps the parent context lean.
* **Deploy `branch` Workspace Subagents**:
  - When prototyping experimental features, alternative layout variants, or refactors that might destabilize the working tree.
* **Direct Execution for Micro-Iterations**:
  - Direct execution in the main agent thread is preferred for single-file styling, direct user feedback, or immediate bug fixes to keep feedback latency minimal.

---

## 4. LAN Distributed Architecture Directives

* **Cross-Platform Parity**: Code changes must preserve mobile functionality (Android, iOS) while adding full desktop support (Windows, macOS, Linux).
* **Platform Conditional Cleanliness**: Never allow mobile-only plugins (`gal`, `speech_to_text`, `mobile_scanner`, `flutter_background_service`) to execute unconditionally on desktop platforms.
* **Path Integrity**: Always use `package:path` (`p.basename`, `p.join`) to ensure cross-platform compatibility with Windows backslashes (`\`) and POSIX slashes (`/`).
* **Low-Latency LAN**: Keep the `llama.cpp` RPC protocol on port `50052` fast by preserving embedding and vocab projection layers on the master node.
