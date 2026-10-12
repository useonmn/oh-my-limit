# Oh My Limit

## 0. Research Log

- Context: a native macOS menu bar utility, not a website or marketing surface.
- Embedded references: considered Apple, Raycast, and Linear; selected the Apple
  reference and minimalist utility guidance for system typography, compact
  controls, neutral surfaces, and semantic color.
- Native AppKit popovers and controls are the interaction reference. Web-only
  galleries, browser breakpoints, React tooling, image mockups, and Lighthouse
  do not describe this surface; native rendering and keyboard checks replace them.
- The evidence harness must render the actual SwiftUI views, not substitute an
  image for the interface. Preview data is visibly labeled and never persisted.
- Approved 2026-09-15 reference: `Tracer_mu2lexqv.png` supplied by the user.
  Adopt its dark rounded surface, provider marks inside circular usage rings,
  large percentages, mint accent, and separate selected-account detail area.
  This is a native adaptation, not a pixel clone of the five-provider image:
  show connected accounts only, distinguish the two Codex accounts by name,
  and preserve all real quota windows and account actions.

## 1. Atmosphere & Identity

A compact menu-material instrument in the menu bar. Account rings provide the overview;
one selected account supplies the detail. Monochrome provider marks identify the
service, account names distinguish separate subscriptions. No decorative motion
or promotional copy. Native SwiftUI/AppKit, not a web surface.

The menu bar uses a 14 pt monochrome provider logo followed by a 13 pt
monospaced-digit percentage for at most the first three accounts, in account order.
The image width is capped at 240 pt. Additional accounts appear as a compact `+N` count; countdowns and all accounts
remain in the tooltip and accessibility label rather than widening the item. Replace numeric
ordinals and the generic leading gauge when accounts exist. Render as a native
template image so light, dark and selected menu-bar appearances remain legible.
Account names remain available in the tooltip and accessibility label; do not
change primary-quota, stale or unknown-value rules.

## 2. Color

The panel follows the system appearance over native Liquid Glass on macOS
26 and later (`glassEffect(.regular)` with the 22 pt rounded panel shape).
The September 21 references show wallpaper-responsive native menu surfaces;
the legacy NSVisualEffectView `.menu` material is not an identical recipe.
Keep that behind-window material only for supported macOS 14/15 systems.
The panel is a transparent borderless NSPanel, without an additional popover
frame material or opaque base fill. No tint or transparency setting. Panel tokens are
adaptive: surface `windowBackgroundColor`, group `primary` at 5.5%, selected tile
`primary` at 10% so the glass remains visible, track `primary` at 15%, primary
`labelColor`, secondary `secondaryLabelColor`, separator `separatorColor`.
Accent tokens adapt per appearance: mint `#0B9E6B`/`#30E8A0`, warning
`#9A4E00`/`#FFB45E`, critical `#D92D20`/`#FF654F` (light/dark). Use mint below
80%, orange at 80%, red at 95%. Color never replaces the percentage or state
label.
Warning color marks only the symbol of a warning (error, notice, overdue
reset); the words use the primary label color so they stay legible over
glass vibrancy.
Unknown and expired observations have an empty ring with a dash, not 0%.
Stale values use a muted arc, a tilde and an explicit previous-value label.
Settings retain their adaptive system palette. No new theme toggle.

## 3. Typography

System SF typography, with the system's Korean fallback. Panel roles: title 11 pt
semibold, account 12 pt semibold, body 11 pt, caption 10.5 pt, detail value 11 pt
semibold, ring percentage 17 pt semibold, ring account label 10.5 pt medium.
The popover is scaled to 85%; text never goes below 10.5 pt.
Settings retain their existing type scale (title and body 12 pt).
Percentages and countdown numbers use monospaced digits. Utility controls use small system typography. Long account names truncate with a full accessibility
label; errors wrap instead of clipping.

## 4. Spacing & Layout

Base unit: 4 pt. Named steps: 4, 8, 12, 16, 20, 24.
The popover uses its own 85% scale: steps 4, 7, 10, 12 pt.
Geometry is concentric (WWDC25 design system): inner radius = outer radius - inset.
Panel radius 22 pt; groups and the selected ring tile sit 10 pt from the panel
edge with a 12 pt radius; group content is padded by that same 12 pt, so every
text edge lands on one 22 pt line from the panel edge. The header title starts
on that line and icon glyphs (not their hit areas) end on it. All rounded
shapes use continuous corners.
Popover width: 272 pt. A quiet one-line 34 pt header provides refresh, add and settings.
Below it, a horizontal row of 75 pt account buttons uses 48 pt rings with
5 pt round-capped strokes, 19 pt provider marks, large percentages, account names and quota-window labels.
Center up to three accounts in a 142 pt selector; additional accounts scroll
horizontally in 153 pt to reserve space for native indicators. Selection has a
subtle selected fill and visible focus outline.
Below the selector, a quiet 12 pt-radius group with 12 pt padding shows only
the selected account: a faint fill and a hairline edge, no shadow or layered
material. Its 252 pt outer width, rounded mask, and outer margins stay fixed
whether its content fits or overflows. Only the padded contents scroll; the
group background and 10 pt bottom inset never scroll away.
Use a native overlay scrollbar inside the group so an appearing scrollbar
does not consume content width or reflow text. Keep the indicator usable and
inset from the rounded corners; do not change global macOS scroll preferences.
The selector and header remain visible. Detail rows have 10 pt spacing and
4 pt progress bars. Each quota row is: label and used percent on one line,
the bar, then reset countdown and remaining percent as a caption line.
Spatial model: [scroll-body-shell](https://github.com/changeroa/StyleGallery/blob/main/patterns/viewport-shell/scroll-body-shell.md),
adapted to a bounded native card rather than a web page.
Empty onboarding remains compact, with an existing-account button and service
connection action. No disconnected refresh or permanent footer.
Reset countdowns stay concise; complete local dates appear in tooltips.
Measure the actual SwiftUI content, including errors and notices, and cap the
height at 527 pt. Account selection and data changes must update native popover
sizing after published state commits. Keep `height(for:)` compatible by adding
an optional selected ID. Settings open in the same panel at 320 pt width, using the
same 10 pt inset, 12 pt group radius and 12 pt group padding, with a compact
account-count-dependent height capped at 420 pt; excess content scrolls.
Buttons remain real keyboard-reachable SwiftUI controls; the primary action
uses `.borderedProminent` with the system focus ring.
Native content-stress checks cover empty, two accounts, long labels, missing
windows, stale data, login waiting, and errors in both appearances.

## 5. Components

- `QuotaRow`: label, used percentage, accessible progress bar, reset description.
  States: known, unavailable, expired observation; never invent a reset value.
  Unavailable provider buckets show "알 수 없음" without a filled progress bar.
  Server reset descriptions may be shown when no exact reset timestamp exists.
- `AccountRing`: real selectable button with provider mark, representative used
  percentage, account name, and window label. Codex summaries use only the main
  `codex` quota, weekly first, never reserve or additional-model quotas.
  Antigravity uses its most-consumed known weekly pool.
  Its accessibility label names the account, service, window and freshness.
  Missing data, login progress, stale data and expired reset time stay distinct.
- `AccountCard`: selected account detail: provider mark, alias and identity, quota rows, freshness/error, and
  refresh/reconnect/disconnect actions. States: connecting, loading, live, stale,
  unauthenticated, authenticated-but-quota-unavailable, disconnected. Direct Google
  accounts retain their verified email when quota is denied, with refresh and
  reconnect actions rather than installation instructions. Freshness is always
  explicitly labeled as the last confirmation; stale observations say so.
  Keychain access failures preserve the existing account and cached quota.
  Show a primary "키체인 접근 허용" action only for this typed recovery state.
  It requests access to the selected account's saved credentials without
  browser login. Disable it during refresh/login; explain the macOS
  "항상 허용" choice without promising access after Keychain resets or locks.
- `EmptyState`: brief explanation and one real connection action that opens settings.
- `SettingsView`:
  "로그인 시 실행" reflects the system login-item status, including pending approval.
  The first eligible normal launch defaults on once; subsequent launches never
  re-enable an item the user disabled. Only installed `.app` launches register:
  unbundled executables, App Translocation, mounted `/Volumes/` locations (including
  DMGs), previews, captures and probes never register. Normal launches delete the
  old LaunchAgent plist without bootout. The toggle is disabled in ineligible runs.
  Show a compact connected-account list followed by one
  provider's connection actions, chosen with a segmented control. Do not stack
  every service's setup instructions in the same viewport. Codex and Claude
  offer only the browser login. Antigravity's direct login is primary; its
  secondary local app/CLI action is disclosed. Each account retains alias,
  refresh, reconnect, cancel and disconnect actions. Direct accounts are
  independent; only the local Antigravity account follows external login. CLI
  reports without an email never inherit the previous local identity.
- `Header`: one quiet line with the small app title, a capsule badge for preview
  data when applicable, refresh, a separate add button and a settings menu
  containing settings and quit. Refresh retains its disabled/loading state and
  Command-R; quit retains Command-Q. All three icons share the secondary label
  color; the accent color never tints header chrome. Used-percent meaning comes
  from each quota row's "남음" caption, not a header label.
- Account login and login cancellation use the adaptive
  macOS link color so they remain distinct from disabled metadata in both appearances.

## 6. Motion & Interaction

Use native button, menu, popover, and progress behavior. No decorative movement.
Do not animate progress changes across a quota reset. Honor system reduced-motion
settings. Clicking a ring changes selection immediately without a network request.
Accounts can also move left/right through ring context menus, VoiceOver actions
and the keyboard-reachable settings account menu. Boundary actions are disabled.
Panel dismissal follows outside clicks, app deactivation and Space changes.
The nonactivating panel preserves the previously frontmost application; closing
returns focus only if another application has not already taken it.
One delegate-owned height drives the SwiftUI frame and panel, measured on
committed data, selection, notice and mode changes and every 30 seconds.
Selection survives refresh and reordering; removing it falls back to the first
remaining account. Newly added/login accounts are selected so cancellation stays
reachable. Account login opens the official URL only after the user chooses login.
Cancelling login must stop the pending operation and leave other accounts alone.
Antigravity connection only reads usage. Direct login opens Google's consent page
and keeps account credentials in this app's Keychain service. Disconnect removes
only that direct account's credentials. Local app/setup opening remains explicit,
never part of automatic polling. Login progress ends before quota fetching begins.

## 7. Depth & Surface

Borderless NSPanel backed by one native Liquid Glass surface on macOS 26+,
with the legacy behind-window menu material on macOS 14/15.
The OS owns refraction, blur and the outer edge; do not paint an imitation
gradient or stack a second material beneath it. Clip the complete surface to
the same 22 pt continuous rounded shape, including in the real borderless
panel, so the hosting view cannot leave square corner edges. Chrome stays
flat: icon triggers are plain borderless symbols, grouped content sits in a
faint fill with a hairline edge, and ring selection is a flat selected-content
fill. No custom specular rims, chips, shadows, or decorative gradients. Provider logos
are real vector assets rendered as template images so they tint with the label
color in both appearances, not approximated symbols or emoji.

## 8. Accessibility Constraints & Accepted Debt

All actions are keyboard reachable, have visible focus, and have accessible
names. Progress exposes a used-percentage value. Unknown and stale states are
explicit text. Korean labels are checked on rendered views in both
appearances. The panel follows the system appearance; settings and native
menus retain system behavior. The initial distribution is a locally built,
ad-hoc-signed app; Developer ID signing, notarization, and automatic updates are
outside this first Codex-only implementation.
