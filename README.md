# FakinIt

An experiment in how far plain 2D drawing can pass for 3D. A stick figure rotates, walks and dances in convincing depth, yet everything on screen is LÖVE's basic line primitives run through a small perspective projection. The look is deliberately sketchy: each bone is several offset strokes, the joints are asterisks, and the whole scene goes through a CRT shader with scanlines and chromatic aberration. The dance locks to the beat of the music, with tap tempo to set it.

**Project page:** [chaps.dev/projects/fakinit](https://chaps.dev/projects/fakinit/) has a video of the figure dancing and a screenshot.

![A sketch-style stick figure dancing in fake 3D behind a CRT filter](https://chaps.dev/projects/fakinit/screenshot.png)

## Running it

FakinIt runs on [LÖVE](https://love2d.org/) 11.4. From the repository root:

```bash
love .
```

| Key | Action |
|---|---|
| Tab | Cycle animations (idle, walk, run, dance, carlton) |
| V | Toggle view mode (ortho/demo) |
| P | Toggle projection (ortho view only) |
| 1 / 2 / 3 | Toggle particles / trails / motion blur |
| T | Tap tempo |
| , / . | Decrease / increase BPM |
| 4 | Toggle BPM sync |
| R | Reset beat to the downbeat |
| M | Toggle music |
| Arrow keys | Adjust rotation speed |
| + / - | Zoom in / out |
| Space | Pause rotation |

## How it's built

- `main.lua` holds everything: the Y-axis rotation and projection, a 17-joint skeleton with data-driven animations built from sine harmonics, the sketch renderer, particles, trails, motion blur and the BPM system.
- `conf.lua` sets an 800x600 resizable window; all drawing scales with the window.
- `music.mp3` is the track the dance follows.
- `Promo/` holds a screenshot and a screen recording.
- `LoveLibs/` is [LoveLibs](https://github.com/chrischaps/LoveLibs), vendored as a subtree (not currently used).
