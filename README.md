# DeckTalk

One-tap chat for World of Warcraft players on **Steam Deck** or controller.

Typing on a Steam Deck is slow. DeckTalk gives you a small panel of big buttons
(and keybinds for your back buttons) for the things you say all the time.

## Features
- **8 quick phrases** – "Hi!", "Thanks!", "Ready", "BRB"… fully editable.
  Sent to instance / raid / party chat automatically, or /say when solo.
- **LFG: quest** – posts `LFG [Quest Link]` for your tracked quest in LookingForGroup (or General).
- **Steam Deck note** – "I'm playing on a Steam Deck and typing is slow…"
  - optionally posted automatically when you join a group
  - optionally whispered back once (per 10 min) to anyone who whispers you
- **Keybinds** for everything (Esc → Options → Keybindings → AddOns → DeckTalk) –
  map them to L4/L5/R4/R5 in Steam Input.
- Placeholders: `%q` tracked quest, `%t` target name, `%z` zone.

## Commands
| Command | Does |
|---|---|
| `/dt` | Show / hide panel |
| `/dt config` | Edit phrases and options |
| `/dt scale 1.3` | Make the panel bigger (0.5–2) |
| `/dt reset` | Move panel back to default position |

## Install
Copy the `DeckTalk` folder to `World of Warcraft/_retail_/Interface/AddOns/`.

## License
MIT
