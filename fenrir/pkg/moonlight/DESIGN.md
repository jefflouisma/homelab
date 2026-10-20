# Fenrir web interface

Preserve the pairing dashboard's system font, purple-to-blue background, translucent white cards and white text. The Updates page uses the same visual family and navigation. Extracting a separate framework is unnecessary for these two server-rendered pages.

## Tokens

Background: #720082, #3f00c3, #0047ff gradient. Ink: white. Card: white at 10%; nested surfaces: black at 20%. Action: #006b35 with white text; secondary action: white at 15%. Error: #ffe4e6. Spacing: 0.5rem, 1rem, 1.5rem, 2rem. Radius: 0.5rem and 1rem. Body type: 1rem system sans; heading: clamp(1.75rem,7vw,2.5rem). Secondary text retains at least 80% opacity.

## Layout and primitives

The document owns scrolling. Content width is at most 52rem; padding respects safe-area insets. Cards, status text, native buttons, labelled selects and navigation links are the reusable primitives. Component rows stack below 40rem. Long version identifiers wrap. No fixed-width tables or horizontal scrolling on a 320px phone.

## States and interaction

Show installed, staged, queued and retained versions separately. Buttons have busy/disabled states and visible keyboard focus. Result and failure messages use a polite live region; errors persist until another action. Queued activation says that running sessions must close. Updating and rollback never navigate away or interrupt a game. Poll only while visible; preserve focus and selection across refreshes.

## Accessibility and motion

Use semantic landmarks, one h1, descriptive control labels, 48px minimum tap targets, keyboard navigation and high-contrast action fills. The Updates page needs no animation. Honor reduced-motion preferences wherever shared styling animates. Verify phone and desktop widths, long versions, errors, loading, queued updates, rollback, keyboard focus and page-end visibility in a real browser.

## Accepted scope

The existing pairing page is retained, with a link to Updates. The EmuDeck update control manages ES-DE, its frontend; other bundled emulators remain maintained by the image build. Package compatibility and gameplay require real Linux/GPU/controller testing beyond successful downloads.
