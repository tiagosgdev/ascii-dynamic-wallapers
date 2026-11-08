# ASCII Dynamic Wallpapers

Animated, interactive ASCII-art desktop wallpapers for macOS. Each scene runs live behind your windows, is drawn entirely with text characters on the GPU, and reacts to the mouse when you use the bare desktop.

## Scenes

| Scene | On its own | Click | Cursor | Scroll |
|---|---|---|---|---|
| **Black Hole** | A tilted accretion disk that slowly drifts and changes shape as the view orbits | Adds a tiny black hole that spirals in and merges (up to 3 at once) | Warps the view around it | Zooms in and out |
| **Koi Pond** | Koi swim around the pond | Drops food and the fish swarm to it | Scares the fish | Nothing |
| **Campfire** | Cold, unlit logs until you light them | See below | Nothing | Nothing |
| **Chess** | Your game waits while a warm light drifts across the board | Click a piece, then a square | Lifts your pieces, shows their legal moves and names any piece | Orbits the camera |

### Campfire lifecycle

1. About 6 quick clicks light the fire.
2. It grows for about a minute.
3. It burns for an hour at 80-100% strength. The hour follows the real clock, including time the Mac spends asleep.
4. It fades over about 2 minutes, then goes out until you light it again.

While it's burning, a burst of quick clicks adds 10 minutes. Pressing and holding the mouse button starts the fade straight away and speeds it up, taking about 4.5 seconds from full to nothing.

### Chess

A full game of chess with all the rules, including castling, en passant, promotion and the draw rules. Games are saved, so they survive switching wallpapers and restarting the app.

- **Bot levels:** click one of the three round pips on the rim near the board's bottom corner for Easy, Medium or Hard. The bot runs in a background worker only on its own turn, for at most about a second.
- **Promotion:** a pawn becomes a queen, and you have 3 seconds to click it to change to a rook, bishop or knight.
- **Resign:** hold your king for about a second. With two players, the side to move holds theirs.
- **Bot or friend:** hold the other king for about a second to switch between playing the bot and two players sharing the mouse. The position is kept. A line of light on the board's right-hand rim is on while you're playing the bot.
- **After a game:** the losing king topples. Click the board for a new game, with colours swapped when playing the bot.

## Build and run

You need macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`). It has been tested on macOS 26 with Apple silicon.

```zsh
./build.sh
open "build/ASCII Wallpapers.app"
```

The app adds an `@` item to the menu bar, with no Dock icon.

- **Switch wallpaper:** pick one from the menu, or press `⌃⌥W` for the next one
- **Menu options:** Pause Animation, Open at Login, Quit

To try a scene without installing anything, open one of the `web/*.html` files in a browser that supports WebGL2.

## Good to know

**This app changes your system wallpaper.** The lock screen can only show the system wallpaper, so the app sets it once to a still image of the selected scene, stored in `~/Library/Application Support/ASCII Wallpapers/`. After that it only replaces that image when you switch scenes. Your previous wallpaper isn't restored automatically when you quit.

**Clicks only count on the bare desktop.** Mouse input is ignored when a window is under the cursor.

**The screen saver is experimental.** It plays pre-recorded videos that aren't included in this repo because of their size, and it hasn't worked reliably. To create them, install `ffmpeg`, run `tools/render-saver.sh`, then run `./build.sh` again. The Campfire and Chess have no video yet. The wallpapers work without any of this.

## How it works

```
web/         One self-contained HTML/WebGL2 file per scene, and the shared scenes.json list
mac/         The macOS app (desktop windows, input, switcher) and screen saver
tools/       Records the screen saver videos
build.sh     Compiles everything into build/ASCII Wallpapers.app
```

The Mac app places a borderless web view at desktop level on each display, and forwards mouse input to the page. Each scene renders in two passes: the first computes the colour and brightness of every character cell, and the second draws the matching glyphs from a font atlas and adds bloom.

## Adding a scene

Create `web/<id>.html` and expose this interface. Coordinates are 0-1 fractions from the top-left corner.

```js
window.ascii = {
  pointer(x, y) {},   // cursor moved
  click(x, y) {},     // click on the bare desktop
  release() {},       // optional: mouse button released
  scroll(dy) {},      // scroll over the bare desktop
  setPaused(p) {},    // stop or restart the animation
  warp(seconds) {},   // advance the simulation instantly (time-based scenes)
  frame(t) {},        // render one frame and return a PNG data URL
};
```

Then add it to `web/scenes.json` and rebuild:

```json
{ "id": "<id>", "title": "<Title>", "stillJS": null }
```

`stillJS` is JavaScript that returns a PNG data URL for the lock screen image. Leave it `null` to keep the scene off the lock screen.

## Settings for one machine

Create `~/.config/ascii-wallpapers/config.json` to override any value in a scene's `CFG` on that machine only. This file is optional and stays out of the repo. Restart the app after changing it.

```json
{
  "overrides": {
    "fire": { "cellW": 8, "cellH": 12 }
  }
}
```

Cell sizes are in logical pixels, so characters look half as big on a display at scale 1 as on a Retina display at scale 2. This is the main reason to use an override.

## Platform support

macOS only for now. The scenes in `web/` are standalone and don't depend on macOS, but the host app in `mac/` does, so Linux would need its own version of it.
