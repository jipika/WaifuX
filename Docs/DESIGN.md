# WallHaven Website Bauhaus Redesign - Implementation Plan

## 1. Concept & Vision

**Bauhaus meets macOS wallpaper app** — A radical departure from the dark glassmorphism aesthetic toward pure geometric expression. The redesign channels the Bauhaus school's 1920s revolutionary spirit: primary colors, basic geometric forms, and functional clarity. The site feels like a modernist art poster come to life — bold, confident, and unmistakably designed.

---

## 2. Design Language

### 2.1 Color Palette

| Role | Color | Hex | Usage |
|------|-------|-----|-------|
| **Primary Red** | Bauhaus Red | `#E53935` | CTAs, accent shapes, key interactive elements |
| **Primary Yellow** | Bauhaus Yellow | `#FDD835` | Highlights, hover states, geometric accents |
| **Primary Blue** | Bauhaus Blue | `#1E88E5` | Secondary accents, links, supporting elements |
| **Pure Black** | — | `#212121` | Primary text, strong headlines |
| **Pure White** | — | `#FAFAFA` | Backgrounds, inverted text |
| **Neutral Gray** | — | `#9E9E9E` | Secondary text, borders, subtle elements |
| **Light Gray** | — | `#F5F5F5` | Section backgrounds (alternating) |
| **Dark Gray** | — | `#424242` | Dark section backgrounds |

### 2.2 Typography

**Primary Font:** `DM Sans` (geometric sans-serif, Futura-inspired)
- Weights: 400 (regular), 500 (medium), 700 (bold)
- Used for: Body text, UI elements

**Display Font:** `Space Grotesk` (geometric with character)
- Weights: 500 (medium), 700 (bold)
- Used for: Headlines, hero text, feature titles

**Bauhaus Accent:** Large display numbers and geometric text treatments

**Type Scale:**
| Element | Size | Weight | Font |
|---------|------|--------|------|
| Hero Title | 72px / 64px (mobile) | 700 | Space Grotesk |
| Section Title | 48px / 36px (mobile) | 700 | Space Grotesk |
| Card Title | 24px | 700 | DM Sans |
| Body | 18px | 400 | DM Sans |
| Small/Label | 14px | 500 | DM Sans |
| Caption | 12px | 400 | DM Sans |

### 2.3 Geometric System

**Primary Shapes:**
- **Circle** — `border-radius: 50%` — Represents motion, infinity
- **Triangle** — CSS `clip-path: polygon()` — Direction, tension, dynamic movement
- **Square/Rectangle** — Clean 90° corners — Stability, order, structure
- **Diagonal** — Used in backgrounds and dividers — Bauhaus dynamic composition

**Geometric Decorators:**
- Red circle (48px) — Top-left hero accent
- Yellow triangle (64px) — Right side geometric burst
- Blue square (32px) — Card accents, dot patterns
- Black diagonal stripe — Section dividers

### 2.4 Grid System

**12-Column Grid:**
- Max width: 1200px
- Column gap: 24px
- Margin: 24px (mobile) / 48px (tablet) / 80px (desktop)

**Vertical Rhythm:**
- Base unit: 8px
- Section padding: 120px (desktop) / 80px (tablet) / 60px (mobile)
- Component spacing: 24px / 32px / 48px

**Asymmetric Layouts:**
- Hero: Content left (7 cols), geometric right (5 cols)
- Stats: 3 equal cards with offset positioning
- Features: Zigzag rhythm (left-right alternating)
- Sources: Staggered grid with color blocking

### 2.5 Motion Philosophy

**Minimal, purposeful animations only:**
- No floating blobs or gradient animations
- No smooth scrolling parallax
- **Hover states:** Quick 150ms transforms (scale 1.02, color shift)
- **Entrance:** Single fade-in, 300ms, triggered on scroll
- **Geometric elements:** Subtle rotation on hover (5deg)

---

## 3. Layout & Structure

### 3.1 Page Sections

```
┌─────────────────────────────────────────────────────────────┐
│ NAVBAR (Fixed)                                              │
│ Logo (left) | Nav Links (center) | Download CTA (right)   │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│ HERO SECTION                                                │
│ ┌─────────────────────────────┬───────────────────────────┐ │
│ │ Content (7 cols)           │ Geometric (5 cols)        │ │
│ │ • Badge                    │ • Red circle (top-right)  │ │
│ │ • Title + Description      │ • Yellow triangle          │ │
│ │ • CTA buttons              │ • Blue squares pattern    │ │
│ │ • App preview              │                           │ │
│ └─────────────────────────────┴───────────────────────────┘ │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│ STATS SECTION (3 cards, asymmetric layout)                  │
│ ┌─────────┐ ┌─────────┐ ┌─────────┐                        │
│ │  100%   │ │   3+    │ │    0    │                        │
│ │ (Red)   │ │(Yellow) │ │ (Blue)  │                        │
│ └─────────┘ └─────────┘ └─────────┘                        │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│ FEATURES SECTION                                            │
│ ┌──────────────────────┐                                    │
│ │ Section Header        │ ← Left-aligned, geometric accent │
│ └──────────────────────┘                                    │
│ ┌────────┐ ┌────────┐ ┌────────┐                            │
│ │ Card 1 │ │ Card 2 │ │ Card 3 │ ← 3-col grid             │
│ └────────┘ └────────┘ └────────┘                            │
│ ┌────────┐ ┌────────┐ ┌────────┐                            │
│ │ Card 4 │ │ Card 5 │ │ Card 6 │                            │
│ └────────┘ └────────┘ └────────┘                            │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│ SOURCES SECTION                                             │
│ ┌────────────────────────────────────────────────────────┐  │
│ │ Section Header (centered) + Yellow triangle burst      │  │
│ └────────────────────────────────────────────────────────┘  │
│ ┌───────────────┐                                          │
│ │ WallHaven     │ ← Large left card (Red accent)          │
│ └───────────────┘                                          │
│ ┌───────────────┐ ┌───────────────┐                        │
│ │ MotionBGs     │ │ Anime         │ ← Stacked right (Blue) │
│ └───────────────┘ └───────────────┘                        │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│ TECH ARCHITECTURE                                           │
│ ┌───────────────────────────┬───────────────────────────┐ │
│ │ Content (6 cols)          │ Diagram (6 cols)           │ │
│ │ • Title + Description     │ • CSS/SVG flow diagram     │ │
│ │ • 3 rule types           │ • Geometric nodes          │ │
│ └───────────────────────────┴───────────────────────────┘ │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│ CTA SECTION                                                 │
│ ┌────────────────────────────────────────────────────────┐ │
│ │ Black background | White text | Yellow geometric burst  │ │
│ │ "Start Exploring" + Download buttons                   │ │
│ └────────────────────────────────────────────────────────┘ │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│ FOOTER                                                      │
│ Black background | Logo | Links | Copyright                 │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 Responsive Breakpoints

| Breakpoint | Width | Layout Adjustments |
|------------|-------|-------------------|
| Mobile | < 640px | Single column, stacked content, simplified geometry |
| Tablet | 640px - 1024px | 2-column grids, reduced padding |
| Desktop | > 1024px | Full 12-col grid, all geometric elements |

---

## 4. Section-by-Section Design

### 4.1 Navbar
- **Background:** White (#FAFAFA) with 1px black bottom border
- **Logo:** Red square with white "W" (clip-path)
- **Links:** Black text, Yellow underline on hover
- **CTA:** Red filled button, white text
- **Mobile:** Hamburger menu with full-screen overlay

### 4.2 Hero Section
- **Background:** White
- **Left Column:**
  - Badge: Black pill with white text + blue square
  - Title: "Beautiful Wallpapers" (black) + "For Creators" (red)
  - Description: Gray body text
  - CTA: Red button (Download) + Black outlined (GitHub)
  - Preview: App screenshot with black border, no shadow
- **Right Column:**
  - Red circle (top-right, 200px, semi-transparent)
  - Yellow triangle (rotated 15deg)
  - Blue square pattern (3 squares, staggered)
  - All elements use CSS clip-path, no images

### 4.3 Stats Section
- **Background:** Light Gray (#F5F5F5)
- **Layout:** 3 cards, center card slightly elevated
- **Card Design:**
  - White background, 2px solid border (colored by type)
  - Large number in primary color (Space Grotesk, 64px)
  - Title in black, description in gray
  - Red card: "100%" stat
  - Yellow card: "3+" stat
  - Blue card: "0" stat

### 4.4 Features Section
- **Background:** White
- **Section Header:**
  - Left-aligned title (Space Grotesk, 48px)
  - Yellow diagonal stripe behind title
  - Red circle accent (32px) top-right of header
- **Feature Cards (6 total, 3x2 grid):**
  - White background, 2px black border
  - Top colored bar (3px) - alternating Red/Yellow/Blue
  - Icon in colored square (48px)
  - Title + description
  - On hover: Background shifts to light gray, border thickens (3px)

### 4.5 Sources Section
- **Background:** White
- **Section Header:**
  - Centered title with yellow triangle burst behind
  - Subtle blue circle accents
- **Source Cards:**
  - WallHaven card: Large, red left border (8px)
  - MotionBGs card: Medium, blue left border
  - Anime card: Medium, yellow left border
  - Each card has geometric icon (circle/triangle/square)

### 4.6 Tech Section
- **Background:** Light Gray (#F5F5F5)
- **Layout:** 2-column (content + diagram)
- **Content:**
  - Title + description left-aligned
  - 3 rule type items with colored number badges
- **Diagram:**
  - Geometric flowchart using CSS
  - Black/gray boxes with colored borders
  - Connecting lines using CSS borders
  - Each node is a rotated square or circle

### 4.7 CTA Section
- **Background:** Pure Black (#212121)
- **Content:** Centered, white text
- **Geometric Elements:**
  - Yellow triangle burst (top-right)
  - Red circle (bottom-left, semi-transparent)
  - Blue diagonal stripes (background pattern)
- **Buttons:**
  - Primary: White button, black text
  - Secondary: White outlined, white text

### 4.8 Footer
- **Background:** Black
- **Layout:** Logo left, links center, copyright right
- **All text:** White or gray
- **Geometric accent:** Small red/yellow/blue squares in a row

---

## 5. Component Inventory

### 5.1 Buttons

**Primary Button (Red)**
- Background: #E53935
- Text: White, 14px, DM Sans Medium
- Padding: 12px 24px
- Border-radius: 0 (Bauhaus sharp corners)
- Hover: Background darkens to #C62828
- Active: Scale 0.98

**Secondary Button (Outlined)**
- Background: Transparent
- Border: 2px solid Black (#212121)
- Text: Black, 14px, DM Sans Medium
- Hover: Background #212121, Text White
- Active: Scale 0.98

**Ghost Button (Text)**
- No background or border
- Text: Black, underline on hover
- Transition: 150ms

### 5.2 Cards

**Feature Card**
- Size: Flexible (fills grid column)
- Background: White
- Border: 2px solid #212121
- Top accent bar: 3px (Red/Yellow/Blue)
- Padding: 24px
- Icon container: 48px colored square
- Hover: Background #F5F5F5, border-width 3px

**Stat Card**
- Size: ~300px width
- Background: White
- Border: 2px solid (colored by type)
- Number: 64px Space Grotesk Bold (colored)
- Title: 18px DM Sans Bold (black)
- Description: 14px DM Sans Regular (gray)

**Source Card**
- Variable sizes (hero + secondary pattern)
- Background: White
- Left border: 8px colored
- Icon: Geometric shape with color
- Hover: Slight translateY (-4px)

### 5.3 Navigation

**Nav Link**
- Text: 14px DM Sans Medium, #212121
- Underline: 2px Yellow on hover (animated from left)
- Active state: Red underline

**Language Switcher**
- Style: Text buttons (no background)
- Active: Black background, white text
- Inactive: Gray text
- Position: Fixed top-right

### 5.4 Geometric Elements

**Red Circle**
- Size: Variable (24px to 200px)
- Color: #E53935
- Opacity: 0.2 to 1.0 (varies by use)
- Used in: Hero accent, stat cards, decorative bursts

**Yellow Triangle**
- Created via: CSS clip-path: polygon(50% 0%, 0% 100%, 100% 100%)
- Color: #FDD835
- Rotation: Various (0deg to 45deg)
- Used in: Section bursts, decorative accents

**Blue Square**
- Size: 16px to 64px
- Color: #1E88E5
- Used in: Pattern repeats, icon containers, decorative

**Diagonal Stripe**
- Created via: CSS linear-gradient (45deg)
- Colors: Black/White alternating
- Used in: Section dividers, background patterns

### 5.5 Typography Components

**Badge/Pill**
- Background: Black
- Text: White, 12px, DM Sans Medium
- Padding: 6px 12px
- Contains: Text + optional geometric icon

**Section Title**
- Font: Space Grotesk Bold
- Size: 48px desktop / 36px mobile
- Color: #212121
- Optional: Geometric accent behind/beside

**Body Text**
- Font: DM Sans Regular
- Size: 18px
- Line-height: 1.6
- Color: #424242

---

## 6. Technical Approach

### 6.1 File Structure

```
docs/
├── index.html           # Main HTML (Bauhaus redesigned)
├── DESIGN.md            # This specification
├── Bauhaus/
│   ├── styles/
│   │   ├── bauhaus-base.css      # CSS variables, resets
│   │   ├── bauhaus-components.css # Component styles
│   │   ├── bauhaus-layout.css    # Grid system, sections
│   │   └── bauhaus-utilities.css # Utility classes
│   ├── scripts/
│   │   ├── i18n-bauhaus.js       # Multi-language support
│   │   └── bauhaus-interactions.js # Hover/click handlers
│   └── assets/
│       └── geometric/            # SVG geometric shapes (if needed)
├── og.png               # Open Graph image (keep existing)
├── logo.png             # App logo (keep existing)
└── app-screenshot-real.png  # App screenshot (keep existing)
```

### 6.2 CSS Architecture

**bauhaus-base.css:**
```css
:root {
  /* Colors */
  --bauhaus-red: #E53935;
  --bauhaus-yellow: #FDD835;
  --bauhaus-blue: #1E88E5;
  --bauhaus-black: #212121;
  --bauhaus-white: #FAFAFA;
  --bauhaus-gray: #9E9E9E;
  --bauhaus-light-gray: #F5F5F5;
  --bauhaus-dark-gray: #424242;

  /* Typography */
  --font-display: 'Space Grotesk', sans-serif;
  --font-body: 'DM Sans', sans-serif;

  /* Spacing */
  --space-unit: 8px;
  --section-padding: 120px;
}
```

**No Tailwind** — Pure CSS with CSS variables for Bauhaus authenticity and smaller file size.

### 6.3 JavaScript

- **i18n:** Same translation object structure, simplified
- **Interactions:** Minimal vanilla JS for:
  - Language switching
  - Mobile menu toggle
  - Scroll-triggered fade-ins (IntersectionObserver)
  - Button hover enhancements

### 6.4 Multi-Language Support

Maintain existing three-language structure (zh, en, ja) with the translation object pattern.

---

## 7. Implementation Phases

### Phase 1: Foundation (Day 1)
- [ ] Create file structure (bauhaus-base.css, bauhaus-components.css, etc.)
- [ ] Set up CSS variables and base styles
- [ ] Implement 12-column grid system
- [ ] Create geometric shape CSS utilities (circle, triangle, square)
- [ ] Build typography system

### Phase 2: Core Layout (Day 1-2)
- [ ] Implement navbar with mobile menu
- [ ] Build hero section with geometric elements
- [ ] Create stats section (3 cards)
- [ ] Implement features grid (6 cards)
- [ ] Build sources section with staggered layout

### Phase 3: Remaining Sections (Day 2)
- [ ] Tech architecture section with flow diagram
- [ ] CTA section with bold typography
- [ ] Footer with geometric accents
- [ ] Responsive adjustments

### Phase 4: Polish (Day 2-3)
- [ ] Multi-language support (zh/en/ja)
- [ ] Scroll animations (IntersectionObserver)
- [ ] Hover states on all interactive elements
- [ ] Mobile menu functionality
- [ ] Cross-browser testing

### Phase 5: Validation (Day 3)
- [ ] Accessibility check (contrast, semantic HTML)
- [ ] Responsive testing (mobile, tablet, desktop)
- [ ] Performance check (file sizes, load time)
- [ ] Final visual QA against design spec

---

## 8. Atomic Commit Strategy

| Commit | Message | Changes |
|--------|---------|---------|
| `feat: setup bauhaus css foundation` | CSS variables, base reset, grid system | bauhaus-base.css |
| `feat: add geometric shape utilities` | Circle, triangle, square CSS utilities | bauhaus-utilities.css |
| `feat: implement typography system` | Font imports, type scale, headings | bauhaus-base.css |
| `feat: build navbar component` | Fixed nav, mobile menu | index.html, components |
| `feat: create hero section` | Hero layout + geometric accents | index.html, layout |
| `feat: add stats section` | 3 stat cards with colors | index.html, components |
| `feat: implement features grid` | 6 feature cards, 3x2 grid | index.html, components |
| `feat: build sources section` | Staggered source cards | index.html, components |
| `feat: add tech architecture section` | Flow diagram with CSS | index.html, components |
| `feat: create CTA section` | Bold CTA with geometric burst | index.html, components |
| `feat: implement footer` | Footer with geometric accents | index.html, components |
| `feat: add multi-language support` | zh/en/ja translations | i18n-bauhaus.js |
| `feat: implement scroll animations` | IntersectionObserver fades | bauhaus-interactions.js |
| `feat: add responsive breakpoints` | Mobile/tablet/desktop layouts | All CSS files |
| `fix: responsive layout issues` | Media query adjustments | CSS files |
| `fix: browser compatibility` | Vendor prefixes, fixes | CSS files |
| `chore: final polish and QA` | Hover states, spacing | All files |

---

## 9. Key Differences from Current Design

| Aspect | Current | Bauhaus Redesign |
|--------|---------|-----------------|
| Color | Gradient greens, glassmorphism | Pure primary colors, flat |
| Background | Dark (#0a0a0a) | Light (#FAFAFA) with contrast sections |
| Shapes | Blurred blobs, rounded | Sharp geometry, clip-path |
| Shadows | Deep soft shadows | None or minimal (1px borders) |
| Typography | Inter + Space Grotesk | DM Sans + Space Grotesk |
| Animations | Complex floating/gradient | Minimal, purposeful |
| Layout | Centered, uniform | Asymmetric, dynamic |
| Effects | Glass blur, glow | Clean, flat, geometric bursts |

---

## 10. Success Criteria

1. ✅ Page loads without external CSS framework (pure CSS)
2. ✅ All 8 sections render correctly on desktop
3. ✅ Geometric elements visible and properly positioned
4. ✅ Three primary colors (#E53935, #FDD835, #1E88E5) used prominently
5. ✅ Responsive on mobile (320px+), tablet, desktop
6. ✅ Multi-language switching works (zh/en/ja)
7. ✅ All hover states functional
8. ✅ No console errors
9. ✅ Lighthouse performance score > 90
10. ✅ Accessibility: proper contrast ratios, semantic HTML
