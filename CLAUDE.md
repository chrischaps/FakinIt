# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

FakinIt is a LÖVE 2D demo that creates fake 3D graphics using 2D primitives and perspective projection. Features animated stick figures with hand-drawn sketch aesthetics, dancing to music with BPM sync.

**Language**: Lua 5.1+
**Framework**: LÖVE 2D 11.4

## Running the Project

```bash
love .
```

## Keyboard Controls

| Key | Action |
|-----|--------|
| Tab | Cycle animations (idle, walk, run, dance, carlton) |
| V | Toggle view mode (ortho/demo) |
| P | Toggle projection (ortho view only) |
| 1/2/3 | Toggle particles/trails/motion blur |
| T | Tap tempo for BPM sync |
| ,/. | Decrease/increase BPM |
| 4 | Toggle BPM sync |
| R | Reset beat to downbeat |
| M | Toggle music playback |
| Arrow keys | Adjust rotation speed |
| +/- | Zoom in/out |
| Space | Pause rotation |

## Architecture

### Core Systems (main.lua)

**Projection System**
- `rotateY(point, angle)` - Y-axis rotation matrix
- `project(point)` - Converts 3D to 2D screen coordinates
- `getWindowScale()` - Returns scale factor for responsive rendering
- Two modes: perspective (focalLength/z) and orthographic (fixed scale)

**Animation System**
- Data-driven via `animations` table with `speed` and `apply(joints, baseJoints, t)` functions
- `animateFigure(dt)` - Applies current animation to joint positions
- BPM sync: dance animations use `music.measurePhase` instead of internal timing
- Clean looping requires even integer frequency multipliers in sine waves

**Figure Rendering**
- Joint-based skeleton with 17 joints and 19 bones
- Hand-drawn style: 5-7 offset lines per bone segment, asterisk-style joints
- `drawDancer()` - Renders a figure with position offset, color shift, scale, sketch variation, and animation wobble
- Backup dancers: positioned behind main figure with subtle variations

**Motion Effects**
- Particles: velocity/acceleration-based emission from extremity joints
- Trails: position history for hands/feet with fading lines
- Motion blur: ghosted figure snapshots

**Music/BPM System**
- `music.measurePhase` (0-1) drives dance animation timing
- Tap tempo via `tapTempo()` function
- Audio looping between configurable start/end times

### Key Patterns

**Window-responsive scaling**: All visual elements scale using `getWindowScale()` which returns `min(width/800, height/600)`.

**Sketch variation**: Randomness seeds based on element index create consistent but varied hand-drawn appearance. Each backup dancer has unique seeds via `sketchVariation` parameter.

**Animation variation for backup dancers**:
```lua
{
    poseWobble = 0.24,    -- Joint position randomization amount
    wobbleSpeed = 1.3,    -- Speed of wobble oscillation
    phaseOffset = -0.08,  -- Timing offset in animation
}
```

### File Structure

- `main.lua` - All game logic (~2400 lines)
- `conf.lua` - LÖVE configuration (800x600, resizable)
- `music.mp3` - Audio file for playback
- `LoveLibs/` - Shared library subtree (not currently used by this project)
