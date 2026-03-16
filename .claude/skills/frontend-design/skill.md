Here is the revised skill.md customized for PETAL stack (Phoenix + LiveView + Tailwind) with Mishka Chelekom, liquid glass aesthetics, and performance-first constraints:

text
---
name: frontend-design
description: Create performant, liquid glass frontend interfaces for Phoenix LiveView PETAL apps with high design quality and zero generic AI aesthetics. Optimized for dark-first, battery-friendly, mobile-heavy usage like ticket scanners and event tools.
license: Complete terms in LICENSE.txt
---
Liquid Glass Frontend Design Skill (Phoenix LiveView + Tailwind + Mishka Chelekom)
This skill guides creation of performant, liquid glass interfaces for Phoenix LiveView applications that avoid generic "AI slop" aesthetics. Implements real working code with exceptional attention to dark-first design, GPU-friendly effects, and mobile battery efficiency.

Project Context (Truths you must not violate)
Platform

Framework: Phoenix 1.7+ with LiveView

Language: Elixir

Styling: Tailwind CSS v3/v4 via tailwindcss npm package

UI Library: Mishka Chelekom (Phoenix component library)

Runtime: BEAM (Erlang VM)

Deployment: VPS with OpenLiteSpeed/NGINX or Cloudflare

Performance Context (Non-negotiable)

Target: Ticket scanners, event tools, high-frequency mobile usage

Battery impact: Minimize GPU/CPU; avoid drain

Dark mode: Default and dominant (OLED-friendly)

Glass effects: Simulated via gradients/shadows, not heavy filters

Design Thinking (MANDATORY before coding)
Before writing code, do a short internal plan and commit to a BOLD liquid glass aesthetic:

Purpose: What is the user doing? (scanning, checking in, viewing tickets)

Tone: Choose one—refined dark glass, neon-tinted scanner UI, muted industrial

Performance budget: No more than one backdrop-blur element per view on mobile

Signature moment: One memorable detail (subtle edge sheen, depth shadow, gradient shift)

CRITICAL: Intentionality beats intensity. Performance beats realism.

Liquid Glass Design Laws (Hard Rules)
1) Dark-first, always
Background: Deep slate/ink (#020617, #0f172a, #1e1b4b)

OLED black: Use #000000 only for true black screens; prefer #020617 for depth

Text: High contrast on dark (slate-50, slate-100)

No light mode default—if theme toggle exists, dark is system default

2) Glass via layers, not filters
PERFORMANCE RULE: Prefer static gradients + shadows over backdrop-filter

Allowed techniques (cheap):

bg-white/5 to bg-white/15 semi-transparent layers

bg-gradient-to-br from white/10 to transparent

Soft shadows: shadow-[0_18px_40px_rgba(0,0,0,0.5)]

Inner borders: border border-white/10

Restricted techniques (expensive):

backdrop-filter: blur() on mobile (use @media (min-width: 768px) only)

SVG displacement filters (feTurbulence, feDisplacementMap)

Animated blobs behind glass layers

Multiple nested blurred containers

3) Tokens first (no ad-hoc hex values)
Define in assets/css/app.css or Tailwind config:

css
:root {
  --glass-bg: rgba(255, 255, 255, 0.07);
  --glass-border: rgba(255, 255, 255, 0.12);
  --glass-shadow: 0 18px 40px rgba(0, 0, 0, 0.55);
  --color-bg-base: #020617;
  --color-accent: #22d3ee;
}
4) Accent colors: controlled, subtle glow
Primary accent: Cyan/blue (#22d3ee, #38bdf8) or violet (#a78bfa)—cool tints for glass feel

Success: Emerald (#34d399) for scan confirmations

Alert: Rose (#f43f5e) for errors

Neutrals: Slate scale only (slate-50 to slate-950)

5) Typography: clean, geometric, readable
Display: Geist, Inter, or Geist Mono for technical/editorial feel

Body: Inter, Geist, or system sans with tight tracking

Scanner context: Large, bold numbers; high contrast; generous line-height

6) Motion: minimal, purposeful
No continuous animations on scanner views (batteries die)

One subtle hover state per interactive element

Respect prefers-reduced-motion

7) Composition: depth through stacking
Layer order: Background gradient → Noise/texture → Glass card → Content → Highlight sheen

Use relative + z-10 stacking; avoid absolute soup

Scanner camera view: Full-bleed, no glass overlay on video element

8) Accessibility is not optional
Minimum 4.5:1 contrast ratio (WCAG AA)

Focus rings: focus-visible:ring-2 focus-visible:ring-cyan-400/50

Touch targets: Minimum 44×44dp

Screen reader labels on all scan states

Output Requirements (What you must produce)
When the user asks for UI work:

State the chosen aesthetic direction in one sentence.

List components/files to create/modify (concrete paths).

Provide working Phoenix/LiveView code (not pseudocode) with:

Tailwind utility classes (no arbitrary values in class soup)

Dark-first color decisions

Hover/focus/active states

Mobile-first responsive (touch-friendly)

Performance comments noting blur restrictions

If using Mishka Chelekom components, show integration pattern.

Liquid Glass Defaults (use unless overridden)
Aesthetic defaults

Dark ink backgrounds with subtle blue/cyan gradient hints

Glass cards: Semi-transparent white layers (7-12% opacity) with soft shadows

Depth created via stacking, not blur

Scanner contexts: High contrast, large type, clear status states

Performance defaults

backdrop-blur only on @media (min-width: 768px)

Static background images (no animated blobs)

CSS transitions only (no JS animation libraries)

LiveView patches over WebSocket (efficient updates)

Common Liquid Glass Patterns
1. LiveView Component Structure
elixir
defmodule MyAppWeb.GlassComponents do
  use Phoenix.Component

  attr :class, :string, default: ""
  slot :inner_block, required: true

  def glass_card(assigns) do
    ~H"""
    <div class={[
      "relative rounded-2xl overflow-hidden",
      "bg-white/[0.07] border border-white/[0.12]",
      "shadow-[0_18px_40px_rgba(0,0,0,0.55)]",
      @class
    ]}>
      <!-- Fake sheen via gradient -->
      <div class="absolute inset-0 bg-gradient-to-br from-white/[0.10] to-transparent pointer-events-none"></div>
      <div class="relative z-10 p-6">
        <%= render_slot(@inner_block) %>
      </div>
    </div>
    """
  end
end
2. Status Indicators (no glass, pure color)
elixir
# Scanner ready
<span class="bg-emerald-500/20 text-emerald-400 border border-emerald-500/30 px-3 py-1 rounded-full text-sm font-medium">
  Ready
</span>

# Scanning
<span class="bg-cyan-500/20 text-cyan-400 border border-cyan-500/30 px-3 py-1 rounded-full text-sm font-medium">
  Scanning...
</span>

# Error
<span class="bg-rose-500/20 text-rose-400 border border-rose-500/30 px-3 py-1 rounded-full text-sm font-medium">
  Invalid
</span>
3. Background (static, no animation)
css
/* assets/css/app.css */
.bg-scanner-dark {
  background-image:
    radial-gradient(circle at 0 0, rgba(34, 211, 238, 0.15), transparent 55%),
    radial-gradient(circle at 100% 100%, rgba(167, 139, 250, 0.12), transparent 55%),
    linear-gradient(to bottom, #020617, #020617);
  background-attachment: fixed;
}
4. Mishka Chelekom Integration
elixir
# Use Mishka Chelekom components as base, override with glass styles
alias MishkaChelekom.Components.Button

# In your LiveView template
<Button.button
  variant="solid"
  color="primary"
  class="bg-cyan-500/20 hover:bg-cyan-500/30 text-cyan-300 border border-cyan-500/30 backdrop-blur-sm md:backdrop-blur"
>
  Scan Ticket
</Button.button>
Anti-Slop Checklist (Fail the work if any are true)
Uses backdrop-filter: blur() without @media (min-width: 768px) guard on mobile

Includes animated blobs, floating particles, or continuous motion on scanner UIs

Hardcodes arbitrary hex values instead of tokens

Uses light mode as default

No focus states / poor touch targets / broken mobile layout

"Looks glassy" but tanks performance on mid-range Android devices