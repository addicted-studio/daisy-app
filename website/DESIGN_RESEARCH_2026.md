# Daisy — global design research, July 2026

## The diagnosis

The current direction is polished but too familiar: dark product cards, soft
glass, warm orange and oversized sans headings place Daisy among dozens of
interchangeable AI/SaaS products. It communicates quality, not a point of
view. The flower is a distinctive, ownable asset; the surrounding language
needs to give it more room and character.

## What is changing in 2026

1. **Typography has become brand.** Editorial display type and variable fonts
   are replacing anonymous, all-sans landing pages. The goal is not decoration:
   one expressive display face gives a product memory while a quiet UI face
   protects speed and readability.
2. **Real product beats mood-board abstraction.** The best product sites lead
   with a useful, legible product moment rather than a speculative 3D render or
   an AI gradient.
3. **Human texture is a reaction to AI sameness.** A little imperfect grain,
   a tactile paper-like surface and human language feel current when used
   sparingly. Texture must never compete with small UI text.
4. **Clarity wins over trend theatre.** Heavy glass, low-contrast metadata,
   animated everything and vague taglines age quickly. Motion should explain a
   state, not decorate a rectangle.
5. **macOS needs a native core.** The app should respect platform materials,
   system type, focus behaviour, semantic colours and user settings. Marketing
   can be expressive; recording, privacy and settings cannot be ambiguous.

Sources: [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/),
[Apple macOS design resources](https://developer.apple.com/design/resources/),
[Figma's 2026 web-design research](https://www.figma.com/resource-library/web-design-trends/),
[Creative Bloq's typography review](https://www.creativebloq.com/design/fonts-typography/breaking-rules-and-bringing-joy-top-typography-trends-for-2026),
and [its visual-design review](https://www.creativebloq.com/design/graphic-design/texture-warmth-and-tactile-rebellion-the-big-graphic-design-trends-for-2026).

## Chosen territory: Daisy as a "quiet garden utility"

Not literal flowers, not cottagecore, not a corporate dashboard. Daisy is a
small living signal that protects the conversation while it works in the
periphery. The visual system is a contemporary editorial shell around a precise
native utility.

### Colour

| Token | Value | Role |
| --- | --- | --- |
| Parchment | `#F3F0E7` | Main marketing canvas |
| Ink | `#171A15` | Primary text and app night surface |
| Forest | `#214131` | Structural dark green |
| Signal | `#DDFE57` | Active flower centre, one primary moment |
| Moss | `#8DAE55` | Success and supporting detail |
| Rose | `#F08A68` | Voice-note mode only |
| Lilac | `#AFA0EE` | Dictation mode only |

Signal green is not a generic CTA colour: it is Daisy's heartbeat. Buttons use
ink/parchment contrast; the flower and active capture own the vivid colour.

### Type

- **Display:** `Iowan Old Style`, `Baskerville`, `Georgia`, serif. Editorial,
  warm, and already at home on a Mac—no external font request or tracking.
- **Interface/body:** SF Pro / system UI. Familiar, fast and native to Daisy's
  macOS audience.
- **Technical metadata:** SF Mono / system mono, only for timestamps, paths
  and state labels.

### Layout and motion

- Treat the home page as a paced story: manifesto, product proof, modes,
  privacy and download—not a stack of same-shaped cards.
- Use hard editorial rules, generous white space and one asymmetric product
  stage. Remove decorative glass from standard cards.
- Motion is limited to the recording waveform, flower centre and short
  160–220ms state transitions. Honour Reduce Motion.

## Native app migration principles

1. Use platform semantic colours for navigation, lists, selection and error;
   use Daisy colours only for its flower and recording modes.
2. Make the flower the sole persistent branded object. It should communicate
   `idle → recording → processing → ready` without a new dashboard aesthetic.
3. Use a calm night base in the product (`Ink`/`Forest`) and leave the bright
   signal green to actual capture and focus, never for a whole panel.
4. Increase type hierarchy and whitespace before adding decoration. Settings
   should read like macOS settings; the library should read like a well-edited
   archive.
5. Retain WCAG AA contrast and state labels/icons in addition to colour.

## Implementation sequence

1. Rebuild the web landing in this editorial system and remove the old warm
   graphite / glass language.
2. Bring the flower into the revised signature colours on web and macOS.
3. Apply the shared semantic palette in `DaisyColors.swift` in the native app,
   then audit its core screens (Library, recording widget, settings and first
   run) one by one rather than skinning every view indiscriminately.
