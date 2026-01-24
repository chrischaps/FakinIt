-- Fake 3D: Wireframe Cube and Animated Stick Figure
-- Uses perspective projection to create depth illusion

-- CRT Effect shader and canvas
local crtShader = nil
local crtCanvas = nil
local crtEnabled = true

local crtShaderSource = [[
    extern float time;
    extern vec2 resolution;

    // CRT curvature amount
    const float curvature = 0.03;
    // Scanline intensity
    const float scanlineIntensity = 0.15;
    // Chromatic aberration amount
    const float chromaOffset = 0.002;
    // Vignette darkness
    const float vignetteDark = 0.3;

    // Apply barrel distortion for CRT curve
    vec2 curveUV(vec2 uv) {
        uv = uv * 2.0 - 1.0;
        vec2 offset = abs(uv.yx) * curvature;
        uv = uv + uv * offset * offset;
        uv = uv * 0.5 + 0.5;
        return uv;
    }

    vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screen_coords) {
        // Apply CRT curvature
        vec2 curvedUV = curveUV(uv);

        // Check if we're outside the curved screen
        if (curvedUV.x < 0.0 || curvedUV.x > 1.0 || curvedUV.y < 0.0 || curvedUV.y > 1.0) {
            return vec4(0.0, 0.0, 0.0, 1.0);
        }

        // Chromatic aberration - separate RGB channels slightly
        float r = Texel(tex, curvedUV + vec2(chromaOffset, 0.0)).r;
        float g = Texel(tex, curvedUV).g;
        float b = Texel(tex, curvedUV - vec2(chromaOffset, 0.0)).b;
        vec3 col = vec3(r, g, b);

        // Scanlines
        float scanline = sin(curvedUV.y * resolution.y * 1.5) * 0.5 + 0.5;
        scanline = pow(scanline, 1.5) * scanlineIntensity;
        col = col * (1.0 - scanline);

        // Subtle horizontal lines (phosphor effect)
        float phosphor = sin(curvedUV.x * resolution.x * 3.0) * 0.02 + 0.98;
        col = col * phosphor;

        // Vignette
        vec2 vigUV = uv * (1.0 - uv.yx);
        float vig = vigUV.x * vigUV.y * 15.0;
        vig = pow(vig, vignetteDark);
        col = col * vig;

        // Subtle flicker
        float flicker = 1.0 + sin(time * 8.0) * 0.01;
        col = col * flicker;

        // Slight brightness boost to compensate for darkening
        col = col * 1.15;

        return vec4(col, 1.0);
    }
]]

-- Shared projection settings
local camera = {
    focalLength = 400,
    position = { z = 300 }
}

-- Dynamic camera system
local cameraSystem = {
    enabled = true,
    currentShot = 1,
    shotTime = 0,           -- Time spent on current shot
    beatsPerShot = 4,       -- Switch every N beats
    beatCount = 0,          -- Beats since last switch

    -- Current camera values (set directly on cut, no interpolation)
    current = {
        angle = 0,          -- Override figure rotation
        zoom = 300,         -- Camera Z distance
        offsetY = 0,        -- Vertical offset
        offsetX = 0,        -- Horizontal offset
    },

    -- Camera shot presets - dramatic and varied
    shots = {
        {   -- Front medium
            name = "Front",
            angle = 0,
            zoom = 280,
            offsetY = 0,
            offsetX = 0,
            dynamic = false,
        },
        {   -- Extreme low angle (ant's eye view)
            name = "Low Angle",
            angle = 0.15,
            zoom = 220,
            offsetY = 100,  -- Way down low looking up
            offsetX = 0,
            dynamic = false,
        },
        {   -- Full side profile
            name = "Profile",
            angle = math.pi / 2,
            zoom = 260,
            offsetY = 0,
            offsetX = 0,
            dynamic = false,
        },
        {   -- Back 3/4 view
            name = "Back 3/4",
            angle = math.pi * 0.75,
            zoom = 300,
            offsetY = -20,
            offsetX = -30,
            dynamic = false,
        },
        {   -- Extreme close-up (face/chest)
            name = "Extreme CU",
            angle = 0.05,
            zoom = 140,
            offsetY = -80,  -- Tight on upper body
            offsetX = 0,
            dynamic = false,
        },
        {   -- High wide shot (bird's eye)
            name = "High Wide",
            angle = -0.2,
            zoom = 550,
            offsetY = -60,
            offsetX = 0,
            dynamic = false,
        },
        {   -- Dutch angle side
            name = "Dutch Side",
            angle = math.pi * 0.35,
            zoom = 240,
            offsetY = 30,
            offsetX = 50,
            dynamic = false,
        },
        {   -- Reverse angle
            name = "Reverse",
            angle = math.pi,
            zoom = 300,
            offsetY = 0,
            offsetX = 0,
            dynamic = false,
        },
        {   -- Jib shot (dynamic - big sweeping arc)
            name = "Jib Sweep",
            dynamic = true,
            dynamicType = "jib",
        },
        {   -- Fast orbit (dynamic)
            name = "Orbit",
            dynamic = true,
            dynamicType = "orbit",
        },
        {   -- Dramatic push (dynamic zoom)
            name = "Push In",
            dynamic = true,
            dynamicType = "push",
        },
    },
}

-- Get the effective angle for a camera shot (handles dynamic shots)
local function getCameraShotValues(shot, shotTime)
    if not shot.dynamic then
        return shot.angle, shot.zoom, shot.offsetY, shot.offsetX
    end

    -- Calculate beat duration for timing dynamic moves (fallback if music not ready)
    local bpm = (music and music.bpm) or 120
    local beatDuration = 60 / bpm

    if shot.dynamicType == "jib" then
        -- Big dramatic jib sweep over 8 beats
        local cycleDuration = beatDuration * 8
        local t = (shotTime % cycleDuration) / cycleDuration
        local smoothT = (1 - math.cos(t * math.pi)) / 2  -- Ease in/out

        -- Massive sweep from back-low to front-high
        local angle = math.pi * 0.8 - smoothT * math.pi * 0.9  -- ~145deg to ~20deg
        local zoom = 450 - smoothT * 280  -- 450 -> 170 (dramatic push in)
        local offsetY = 120 - smoothT * 200  -- Way low (+120) to high (-80)
        local offsetX = 80 * (1 - smoothT * 2)  -- Offset that crosses center

        return angle, zoom, offsetY, offsetX

    elseif shot.dynamicType == "orbit" then
        -- Fast continuous orbit around the figure
        local orbitSpeed = 0.8  -- Much faster rotation
        local angle = shotTime * orbitSpeed
        local zoom = 260 + math.sin(shotTime * 0.5) * 80  -- Big zoom breathing
        local offsetY = math.sin(shotTime * 0.4) * 50  -- Big vertical float

        return angle, zoom, offsetY, 0

    elseif shot.dynamicType == "push" then
        -- Dramatic push in / pull out
        local cycleDuration = beatDuration * 8
        local t = (shotTime % cycleDuration) / cycleDuration
        -- Ping-pong: push in first half, pull out second half
        local pushT = t < 0.5 and (t * 2) or (2 - t * 2)
        local smoothT = pushT * pushT * (3 - 2 * pushT)  -- Smoothstep

        local angle = math.sin(shotTime * 0.3) * 0.3  -- Subtle drift
        local zoom = 400 - smoothT * 260  -- 400 -> 140 -> 400
        local offsetY = -smoothT * 60  -- Rise up as we push in
        local offsetX = math.sin(shotTime * 0.2) * 30  -- Subtle lateral drift

        return angle, zoom, offsetY, offsetX
    end

    -- Fallback
    return shot.angle or 0, shot.zoom or 300, shot.offsetY or 0, shot.offsetX or 0
end

-- Update camera system - called from love.update
local function updateCameraSystem(dt)
    if not cameraSystem.enabled then return end

    cameraSystem.shotTime = cameraSystem.shotTime + dt

    -- Get current shot values (hard cut - no interpolation between shots)
    local shot = cameraSystem.shots[cameraSystem.currentShot]
    local angle, zoom, offsetY, offsetX = getCameraShotValues(shot, cameraSystem.shotTime)

    -- Apply values directly (dynamic shots animate smoothly via getCameraShotValues)
    cameraSystem.current.angle = angle
    cameraSystem.current.zoom = zoom
    cameraSystem.current.offsetY = offsetY
    cameraSystem.current.offsetX = offsetX
end

-- Switch to the next camera shot
local function switchCameraShot()
    if not cameraSystem.enabled then return end

    -- Always pick a different random shot for maximum variety
    local nextShot
    repeat
        nextShot = math.random(1, #cameraSystem.shots)
    until nextShot ~= cameraSystem.currentShot or #cameraSystem.shots == 1

    cameraSystem.currentShot = nextShot
    cameraSystem.shotTime = 0
    cameraSystem.beatCount = 0
end

local cube = {
    vertices = {},
    edges = {},
    angle = 0,
    size = 100,
    rotationSpeed = 1,
    offset = { x = -120, y = 0, z = 0 }
}

local figure = {
    joints = {},       -- Current animated positions
    baseJoints = {},   -- Rest pose
    bones = {},
    angle = 0,
    rotationSpeed = 0.3,
    offset = { x = 120, y = 0, z = 0 },  -- Centered for taller figure
    animTime = 0,
    currentAnim = "idle",
    -- Motion tracking for particles
    prevWorldJoints = {},  -- Previous frame's world-space positions
    velocities = {},       -- Current velocities per joint
    prevVelocities = {},   -- Previous velocities (for acceleration)
}

-- Get the effective rotation angle (camera or figure default)
local function getEffectiveAngle()
    if cameraSystem.enabled and viewMode == "demo" then
        return cameraSystem.current.angle
    else
        return figure.angle
    end
end

-- Visual effects toggles
local effects = {
    particles = true,
    trails = true,
    motionBlur = true,
}

-- Backup dancers configuration
local backupDancers = {
    {
        offset = { x = -120, z = 70 },  -- Behind and to the left
        colorShift = { r = 0.4, g = -0.35, b = 0.15 },  -- Slightly cooler/bluer
        scale = 0.8,
        sketchVariation = 0.3,  -- Adds variation to sketch randomness
        -- Animation variations
        phaseOffset = -0.08,     -- Slightly behind in animation timing
        poseWobble = 0.24,       -- Amount of random pose variation
        wobbleSpeed = 1.3,       -- Speed of pose wobble
    },
    {
        offset = { x = 120, z = 70 },   -- Behind and to the right
        colorShift = { r = 0.6, g = -0.45, b = 0.15 },  -- Slightly warmer/redder
        scale = 0.8,
        sketchVariation = 0.6,  -- Different variation seed
        -- Animation variations
        phaseOffset = 0.05,      -- Slightly ahead in animation timing
        poseWobble = 0.20,       -- Amount of random pose variation
        wobbleSpeed = 0.9,       -- Speed of pose wobble
    },
}

-- Particle system for motion emphasis
local particles = {
    list = {},
    -- Which joints emit particles and their thresholds (reduced intensity)
    emitters = {
        handL  = { velocityThreshold = 250, accelThreshold = 1200, rate = 0.15 },
        handR  = { velocityThreshold = 250, accelThreshold = 1200, rate = 0.15 },
        footL  = { velocityThreshold = 300, accelThreshold = 1400, rate = 0.12 },
        footR  = { velocityThreshold = 300, accelThreshold = 1400, rate = 0.12 },
        head   = { velocityThreshold = 200, accelThreshold = 1000, rate = 0.08 },
    },
    -- Particle settings (reduced)
    maxParticles = 80,
    baseLifetime = 0.3,
    colors = {
        fast = { 1.0, 0.7, 0.4 },      -- Warm orange for velocity
        accel = { 1.0, 0.9, 0.6 },     -- Bright yellow for acceleration
        decel = { 0.6, 0.8, 1.0 },     -- Cool blue for deceleration
    }
}

-- Beat particles - sketchy lines that burst outward on each beat
local beatParticles = {
    list = {},
    maxParticles = 100,
    particlesPerBeat = 20,  -- How many to spawn per beat
    lifetime = 0.3,         -- How long each particle lives
    speed = 600,            -- Outward velocity (5x bigger spread)
    -- Joints to emit from (with weights for variety)
    emitters = { "handL", "handR", "chest", "footL", "footR" },
    -- Sketchy line settings
    lineLength = 30,        -- 5x bigger lines
    lineWidth = 2,          -- Thicker lines
    wobbleAmount = 20,      -- 5x bigger wobble
}

-- Trail system - stores position history for key joints
local trails = {
    history = {},        -- { jointName = { {x,y,z,age}, ... } }
    maxLength = 8,       -- Number of positions to remember
    interval = 0.016,    -- Time between samples (~60fps)
    timeSinceLastSample = 0,
    -- Which joints get trails
    trackedJoints = { "handL", "handR", "footL", "footR" },
    -- Visual settings
    baseAlpha = 0.4,
    baseWidth = 2,
}

-- Motion blur - stores recent figure snapshots
local motionBlur = {
    snapshots = {},      -- Array of { joints = {}, angle = n, age = n }
    maxSnapshots = 4,
    interval = 0.025,    -- Time between snapshots
    timeSinceLastSnapshot = 0,
    baseAlpha = 0.15,
}

-- BPM / Music sync system
local music = {
    bpm = 120,              -- Beats per minute
    beatTime = 0,           -- Current time within the beat cycle
    beatPhase = 0,          -- 0-1 phase within current beat
    measurePhase = 0,       -- 0-1 phase within 4-beat measure
    beatsPerMeasure = 4,

    -- Tap tempo
    tapTimes = {},          -- Recent tap timestamps
    maxTaps = 4,            -- Number of taps to average
    tapWindow = 2.0,        -- Seconds before taps expire

    -- Visual feedback
    beatPulse = 0,          -- Decays after each beat for visual feedback
    lastBeatPhase = 0,      -- To detect beat crossings

    -- Sync mode
    syncEnabled = true,     -- Whether dance syncs to BPM

    -- Audio playback
    source = nil,           -- The audio source
    loopStart = 0.0,        -- Loop start time in seconds
    loopEnd = 30.0,         -- Loop end time in seconds
    playing = false,        -- Whether music is currently playing
}

-- Choreography system - switches animations on beat
local choreography = {
    enabled = true,
    beatCount = 0,          -- Total beats since start
    -- Sequence: {endBeat, animation}
    sequence = {
        { beats = 8, anim = "idle" },     -- First 4 beats: idle
        { beats = 8, anim = "walk" },     -- First 4 beats: idle
        { beats = 8, anim = "dance" },    -- Next 8 beats: dance
        { beats = math.huge, anim = "carlton" },  -- Rest: carlton
    },
    currentIndex = 1,
    beatsInCurrentSection = 0,
}

-- Background color system (changes on beat)
local background = {
    current = { r = 0.05, g = 0.05, b = 0.1 },
    target = { r = 0.05, g = 0.05, b = 0.1 },
    lerpSpeed = 4,  -- How fast to transition between colors
    palette = {
        { r = 0.05, g = 0.05, b = 0.12 },  -- Deep blue
        { r = 0.08, g = 0.04, b = 0.10 },  -- Purple tint
        { r = 0.06, g = 0.06, b = 0.08 },  -- Dark grey-blue
        { r = 0.04, g = 0.06, b = 0.10 },  -- Teal tint
        { r = 0.07, g = 0.04, b = 0.08 },  -- Magenta tint
        { r = 0.05, g = 0.07, b = 0.09 },  -- Cyan tint
    },
    currentIndex = 1,
}

-- Radial pulse rings (sound wave effect)
local pulseRings = {
    rings = {},             -- Active rings: { radius, alpha, speed }
    maxRings = 16,           -- Maximum concurrent rings
    expandSpeed = 1550,      -- Base expansion speed in pixels/sec
    fadeSpeed = 0.25,       -- How fast rings fade out (slower = longer visible)
    baseAlpha = 0.04,        -- Starting opacity (lower = more subtle)
    lineWidth = 15,          -- Ring line thickness (thicker)
    spawnOnBeat = true,     -- Auto-spawn on beats
}

-- Beat detection system
local beatDetection = {
    analyzed = false,
    analyzing = false,
    detectedBPM = nil,
    confidence = 0,
    firstBeatTime = 0,      -- Time offset of first detected beat
    beatTimes = {},         -- Array of detected beat times
    energyEnvelope = {},    -- Energy over time for visualization
    onsets = {},            -- Detected onset times
    -- Analysis parameters
    windowSize = 1024,      -- Samples per analysis window (~23ms at 44100Hz)
    hopSize = 512,          -- Overlap between windows
    minBPM = 60,
    maxBPM = 200,
    onsetThreshold = 1.5,   -- Multiplier above local average to count as onset
}

--[[
    Beat Detection Algorithm:
    1. Load audio as SoundData for sample access
    2. Calculate energy envelope (RMS in windows)
    3. Detect onsets (sudden energy increases)
    4. Build interval histogram from onset times
    5. Find dominant interval = tempo
    6. Refine using autocorrelation
    7. Find phase offset for first beat
]]

-- Calculate RMS energy of a sample range
local function calculateEnergy(soundData, startSample, numSamples)
    local sum = 0
    local channels = soundData:getChannelCount()
    local totalSamples = soundData:getSampleCount()

    for i = 0, numSamples - 1 do
        local idx = startSample + i
        if idx < totalSamples then
            for c = 1, channels do
                local sample = soundData:getSample(idx, c)
                sum = sum + sample * sample
            end
        end
    end

    return math.sqrt(sum / (numSamples * channels))
end

-- Detect onsets from energy envelope
local function detectOnsets(envelope, hopSize, sampleRate)
    local onsets = {}
    local windowLen = 8  -- Compare against recent average

    for i = windowLen + 1, #envelope do
        -- Calculate local average
        local avg = 0
        for j = i - windowLen, i - 1 do
            avg = avg + envelope[j]
        end
        avg = avg / windowLen

        -- Check if current energy is significantly above average
        if avg > 0 and envelope[i] > avg * beatDetection.onsetThreshold then
            -- Also check it's a local peak
            if envelope[i] > (envelope[i-1] or 0) and
               envelope[i] >= (envelope[i+1] or 0) then
                local timeInSeconds = (i - 1) * hopSize / sampleRate
                table.insert(onsets, timeInSeconds)
            end
        end
    end

    return onsets
end

-- Build histogram of inter-onset intervals and find dominant BPM
local function estimateBPM(onsets, minBPM, maxBPM)
    if #onsets < 4 then return nil, 0 end

    local minInterval = 60 / maxBPM  -- seconds
    local maxInterval = 60 / minBPM

    -- Build histogram of intervals (quantized to 1 BPM resolution)
    local histogram = {}
    for bpm = minBPM, maxBPM do
        histogram[bpm] = 0
    end

    -- Count intervals that fall into each BPM bucket
    for i = 1, #onsets - 1 do
        for j = i + 1, math.min(i + 8, #onsets) do  -- Look at nearby onsets
            local interval = onsets[j] - onsets[i]

            -- Check for direct interval and subdivisions (half, quarter beats)
            for divisor = 1, 4 do
                local adjustedInterval = interval / divisor
                if adjustedInterval >= minInterval and adjustedInterval <= maxInterval then
                    local bpm = math.floor(60 / adjustedInterval + 0.5)
                    if bpm >= minBPM and bpm <= maxBPM then
                        -- Weight by divisor (prefer direct beats)
                        histogram[bpm] = (histogram[bpm] or 0) + (1 / divisor)
                        -- Also add to nearby bins for smoothing
                        if bpm > minBPM then histogram[bpm-1] = (histogram[bpm-1] or 0) + (0.5 / divisor) end
                        if bpm < maxBPM then histogram[bpm+1] = (histogram[bpm+1] or 0) + (0.5 / divisor) end
                    end
                end
            end
        end
    end

    -- Apply preference for common tempo range (90-150 BPM)
    -- Music is most commonly in this range
    for bpm = minBPM, maxBPM do
        if bpm >= 90 and bpm <= 150 then
            histogram[bpm] = histogram[bpm] * 1.5  -- Boost common range
        elseif bpm >= 75 and bpm < 90 then
            histogram[bpm] = histogram[bpm] * 1.2  -- Slight boost
        elseif bpm > 150 and bpm <= 170 then
            histogram[bpm] = histogram[bpm] * 1.2  -- Slight boost
        end
    end

    -- Find peak in histogram
    local bestBPM = nil
    local bestCount = 0
    for bpm = minBPM, maxBPM do
        if histogram[bpm] > bestCount then
            bestCount = histogram[bpm]
            bestBPM = bpm
        end
    end

    -- If detected BPM is very low (< 85), check if double tempo has good support
    -- This catches the "half tempo" problem
    if bestBPM and bestBPM < 85 then
        local doubleBPM = bestBPM * 2
        if doubleBPM <= maxBPM then
            -- Check support around the doubled tempo
            local doubleSupport = 0
            for delta = -2, 2 do
                local checkBPM = doubleBPM + delta
                if checkBPM >= minBPM and checkBPM <= maxBPM then
                    doubleSupport = doubleSupport + (histogram[checkBPM] or 0)
                end
            end
            -- If double tempo has reasonable support, prefer it
            -- (most music is 90+ BPM, so half-tempo detection is usually wrong)
            if doubleSupport > bestCount * 0.3 then
                print(string.format("[Beat Detection] Correcting half-tempo: %d -> %d BPM", bestBPM, doubleBPM))
                bestBPM = doubleBPM
                bestCount = doubleSupport
            end
        end
    end

    -- Calculate confidence (how peaked is the histogram?)
    local totalCount = 0
    for bpm = minBPM, maxBPM do
        totalCount = totalCount + histogram[bpm]
    end
    local confidence = totalCount > 0 and (bestCount / totalCount * 10) or 0
    confidence = math.min(1, confidence)

    return bestBPM, confidence
end

-- Find the phase offset (time of first beat)
local function findBeatPhase(onsets, bpm)
    if not bpm or #onsets < 2 then return 0 end

    local beatInterval = 60 / bpm

    -- Use histogram to find most common phase
    local numBins = 16
    local phaseHistogram = {}
    for i = 1, numBins do phaseHistogram[i] = 0 end

    for _, onset in ipairs(onsets) do
        local phase = (onset % beatInterval) / beatInterval
        local bin = math.floor(phase * numBins) + 1
        bin = math.max(1, math.min(numBins, bin))
        phaseHistogram[bin] = phaseHistogram[bin] + 1
    end

    -- Find peak phase
    local bestBin = 1
    local bestCount = 0
    for i = 1, numBins do
        if phaseHistogram[i] > bestCount then
            bestCount = phaseHistogram[i]
            bestBin = i
        end
    end

    -- Convert back to time offset
    local phaseOffset = ((bestBin - 0.5) / numBins) * beatInterval

    -- Find the first onset near this phase
    for _, onset in ipairs(onsets) do
        local phase = onset % beatInterval
        if math.abs(phase - phaseOffset) < beatInterval * 0.2 or
           math.abs(phase - phaseOffset - beatInterval) < beatInterval * 0.2 then
            return onset
        end
    end

    return onsets[1] or 0
end

-- Main analysis function (called from love.load)
local function analyzeBeatStructure(soundData)
    if not soundData then return false end

    beatDetection.analyzing = true
    print("[Beat Detection] Starting analysis...")

    local sampleRate = soundData:getSampleRate()
    local totalSamples = soundData:getSampleCount()
    local duration = totalSamples / sampleRate

    print(string.format("[Beat Detection] Audio: %.1fs, %dHz, %d channels",
        duration, sampleRate, soundData:getChannelCount()))

    -- Step 1: Calculate energy envelope
    local envelope = {}
    local windowSize = beatDetection.windowSize
    local hopSize = beatDetection.hopSize

    for i = 0, totalSamples - windowSize, hopSize do
        local energy = calculateEnergy(soundData, i, windowSize)
        table.insert(envelope, energy)
    end
    beatDetection.energyEnvelope = envelope
    print(string.format("[Beat Detection] Calculated %d energy windows", #envelope))

    -- Step 2: Detect onsets
    local onsets = detectOnsets(envelope, hopSize, sampleRate)
    beatDetection.onsets = onsets
    print(string.format("[Beat Detection] Found %d onsets", #onsets))

    -- Step 3: Estimate BPM from onset intervals
    local estimatedBPM, confidence = estimateBPM(onsets, beatDetection.minBPM, beatDetection.maxBPM)

    if estimatedBPM then
        beatDetection.detectedBPM = estimatedBPM
        beatDetection.confidence = confidence

        -- Step 4: Find beat phase
        beatDetection.firstBeatTime = findBeatPhase(onsets, estimatedBPM)

        print(string.format("[Beat Detection] Detected BPM: %d (confidence: %.0f%%)",
            estimatedBPM, confidence * 100))
        print(string.format("[Beat Detection] First beat at: %.3fs", beatDetection.firstBeatTime))

        beatDetection.analyzed = true
        beatDetection.analyzing = false
        return true
    else
        print("[Beat Detection] Could not determine BPM")
        beatDetection.analyzing = false
        return false
    end
end

-- Sync music timing to detected beats
local function syncToDetectedBeats()
    if not beatDetection.analyzed or not beatDetection.detectedBPM then return end

    -- Update global music BPM
    music.bpm = beatDetection.detectedBPM

    -- If music is playing, sync beat phase
    if music.source and music.playing then
        local currentPos = music.source:tell()
        local beatInterval = 60 / music.bpm

        -- Calculate where we are in the beat cycle, accounting for first beat offset
        local adjustedPos = currentPos - beatDetection.firstBeatTime
        local beatNumber = adjustedPos / beatInterval

        -- Set the beat time to match
        music.beatTime = adjustedPos
    end
end

-- Animation definitions
-- Each animation has:
--   speed: cycles per second
--   apply: function(joints, baseJoints, t) that modifies joints based on normalized time (0-1)
local animations = {}

animations.idle = {
    name = "Idle (Breathing)",
    speed = 0.35,  -- Slower for longer, more relaxed cycle
    apply = function(joints, base, t)
        -- All frequencies must be even integers for clean looping
        -- Primary breath cycle (1 full breath)
        local breath = math.sin(t * math.pi * 2)
        local breathIn = (breath + 1) / 2

        -- Secondary sway at half speed (completes when breath does 2 cycles)
        -- Since speed=0.35, we slow everything down and use t*2 for sway
        local sway = math.sin(t * math.pi * 2) * 0.3  -- Same freq, will layer with breath

        -- Use phase offset for variation instead of different frequencies
        local swayOffset = math.sin(t * math.pi * 2 + math.pi * 0.5) * 0.4

        local breathAmount = breathIn * 5
        local shoulderRise = breathIn * 4

        -- Chest expansion (exaggerated for stylized rig)
        joints.chest.z = base.chest.z + breathAmount * 0.8
        joints.chest.y = base.chest.y - breathAmount * 0.4

        -- Shoulders rise and widen dramatically
        joints.shoulderL.y = base.shoulderL.y - shoulderRise
        joints.shoulderR.y = base.shoulderR.y - shoulderRise
        joints.shoulderL.x = base.shoulderL.x - breathAmount * 0.5
        joints.shoulderR.x = base.shoulderR.x + breathAmount * 0.5

        -- Head subtle bob (less movement - stays stable)
        joints.head.y = base.head.y - breathIn * 1.2
        joints.neck.y = base.neck.y - breathIn * 1.5

        -- Arms sway with long graceful arcs
        local armSway = (sway + swayOffset) * 4
        joints.elbowL.z = base.elbowL.z + armSway + breath * 4
        joints.elbowR.z = base.elbowR.z - armSway - breath * 4
        joints.handL.z = base.handL.z + armSway * 1.5 + breath * 8
        joints.handR.z = base.handR.z - armSway * 1.5 - breath * 8

        -- Hands trace gentle patterns (using harmonics: 2 and 4)
        joints.handL.x = base.handL.x + math.sin(t * math.pi * 2) * 4
        joints.handL.y = base.handL.y + math.sin(t * math.pi * 4) * 3
        joints.handR.x = base.handR.x + math.sin(t * math.pi * 2 + math.pi) * 4  -- Phase offset
        joints.handR.y = base.handR.y + math.sin(t * math.pi * 4 + math.pi) * 3

        -- Elegant weight shift through narrow waist (same frequency, phase offset)
        local shift = math.sin(t * math.pi * 2 + math.pi * 0.5) * 4
        joints.pelvis.x = base.pelvis.x + shift
        joints.spine.x = base.spine.x + shift * 0.7
        joints.spine.z = base.spine.z + breathAmount * 0.4
        joints.chest.x = base.chest.x + shift * 0.3

        -- Subtle hip movement
        joints.hipL.y = base.hipL.y - math.max(0, shift) * 0.3
        joints.hipR.y = base.hipR.y + math.min(0, shift) * 0.3
    end
}

animations.walk = {
    name = "Walk",
    speed = 1.0,  -- Slower, more deliberate catwalk
    apply = function(joints, base, t)
        local cycle = t * math.pi * 2

        -- Leg phases (opposite)
        local legL = math.sin(cycle)
        local legR = math.sin(cycle + math.pi)

        -- Arm phases (opposite to legs)
        local armL = math.sin(cycle + math.pi)
        local armR = math.sin(cycle)

        -- Body bob (twice per cycle - up at each step's midpoint)
        local bob = -math.abs(math.sin(cycle)) * 6 + 3

        -- Apply body bob through the long torso
        joints.pelvis.y = base.pelvis.y + bob
        joints.spine.y = base.spine.y + bob * 0.9
        joints.chest.y = base.chest.y + bob * 0.7
        joints.neck.y = base.neck.y + bob * 0.4
        joints.head.y = base.head.y + bob * 0.2  -- Head stays very stable

        -- Hip sway (exaggerated through narrow waist)
        local hipSway = math.sin(cycle) * 7
        joints.pelvis.x = base.pelvis.x + hipSway
        joints.hipL.x = base.hipL.x + hipSway
        joints.hipR.x = base.hipR.x + hipSway

        -- Spine creates S-curve counterpoise
        joints.spine.x = base.spine.x + hipSway * 0.4
        joints.chest.x = base.chest.x - hipSway * 0.3
        joints.neck.x = base.neck.x - hipSway * 0.4

        -- Shoulder counter-rotation (dramatic with wide shoulders)
        joints.shoulderL.x = base.shoulderL.x - hipSway * 0.6
        joints.shoulderR.x = base.shoulderR.x - hipSway * 0.6
        joints.shoulderL.z = base.shoulderL.z - hipSway * 0.3
        joints.shoulderR.z = base.shoulderR.z + hipSway * 0.3

        -- LEFT LEG (long sweeping strides)
        local liftL = math.max(0, legL) * 20
        joints.hipL.y = base.hipL.y + bob
        joints.kneeL.y = base.kneeL.y + bob - liftL * 0.4
        joints.kneeL.z = base.kneeL.z + legL * 35
        joints.kneeL.x = base.kneeL.x + math.max(0, legL) * 3  -- Knee tracks slightly outward
        joints.footL.y = base.footL.y + bob - liftL
        joints.footL.z = base.footL.z + legL * 50  -- Long stride

        -- RIGHT LEG
        local liftR = math.max(0, legR) * 20
        joints.hipR.y = base.hipR.y + bob
        joints.kneeR.y = base.kneeR.y + bob - liftR * 0.4
        joints.kneeR.z = base.kneeR.z + legR * 35
        joints.kneeR.x = base.kneeR.x - math.max(0, legR) * 3
        joints.footR.y = base.footR.y + bob - liftR
        joints.footR.z = base.footR.z + legR * 50

        -- LEFT ARM (long graceful swing)
        joints.shoulderL.y = base.shoulderL.y + bob * 0.4
        joints.elbowL.y = base.elbowL.y + bob * 0.3
        joints.elbowL.z = base.elbowL.z + armL * 25
        joints.elbowL.x = base.elbowL.x - math.abs(armL) * 3  -- Elbow swings out slightly
        joints.handL.y = base.handL.y + bob * 0.2
        joints.handL.z = base.handL.z + armL * 40
        joints.handL.x = base.handL.x + armL * 5  -- Hands cross slightly in front

        -- RIGHT ARM
        joints.shoulderR.y = base.shoulderR.y + bob * 0.4
        joints.elbowR.y = base.elbowR.y + bob * 0.3
        joints.elbowR.z = base.elbowR.z + armR * 25
        joints.elbowR.x = base.elbowR.x + math.abs(armR) * 3
        joints.handR.y = base.handR.y + bob * 0.2
        joints.handR.z = base.handR.z + armR * 40
        joints.handR.x = base.handR.x + armR * 5

        -- Head stays stable but has subtle attitude
        joints.head.z = base.head.z + math.sin(cycle) * 2
        joints.head.x = base.head.x - hipSway * 0.15  -- Slight counter to body
    end
}

animations.run = {
    name = "Run",
    speed = 2.2,  -- Fast but readable
    apply = function(joints, base, t)
        local cycle = t * math.pi * 2

        local legL = math.sin(cycle)
        local legR = math.sin(cycle + math.pi)
        local armL = math.sin(cycle + math.pi)
        local armR = math.sin(cycle)

        -- Dynamic bob with flight phase
        local bob = -math.abs(math.sin(cycle)) * 12 + 6

        -- Aggressive forward lean
        local lean = 12

        -- Upper body drives forward
        joints.pelvis.y = base.pelvis.y + bob
        joints.pelvis.z = base.pelvis.z - lean * 0.2
        joints.spine.y = base.spine.y + bob * 0.8
        joints.spine.z = base.spine.z + lean * 0.6
        joints.chest.y = base.chest.y + bob * 0.6
        joints.chest.z = base.chest.z + lean * 1.2
        joints.neck.y = base.neck.y + bob * 0.3
        joints.neck.z = base.neck.z + lean * 1.5
        joints.head.y = base.head.y + bob * 0.15  -- Head very stable
        joints.head.z = base.head.z + lean * 1.6

        -- Hip rotation drives the stride
        local hipSway = math.sin(cycle) * 8
        joints.pelvis.x = base.pelvis.x + hipSway
        joints.hipL.x = base.hipL.x + hipSway
        joints.hipR.x = base.hipR.x + hipSway

        -- Torso counter-twist
        joints.spine.x = base.spine.x + hipSway * 0.3
        joints.chest.x = base.chest.x - hipSway * 0.4
        joints.shoulderL.x = base.shoulderL.x - hipSway * 0.7
        joints.shoulderR.x = base.shoulderR.x - hipSway * 0.7

        -- LEFT LEG - high knee drive with long reach
        local liftL = math.max(0, legL) * 35
        joints.hipL.y = base.hipL.y + bob
        joints.kneeL.y = base.kneeL.y + bob - liftL * 0.6
        joints.kneeL.z = base.kneeL.z + legL * 50
        joints.footL.y = base.footL.y + bob - liftL
        joints.footL.z = base.footL.z + legL * 70  -- Long powerful stride

        -- RIGHT LEG
        local liftR = math.max(0, legR) * 35
        joints.hipR.y = base.hipR.y + bob
        joints.kneeR.y = base.kneeR.y + bob - liftR * 0.6
        joints.kneeR.z = base.kneeR.z + legR * 50
        joints.footR.y = base.footR.y + bob - liftR
        joints.footR.z = base.footR.z + legR * 70

        -- Arms pump explosively with bent elbows
        joints.shoulderL.y = base.shoulderL.y + bob * 0.3
        joints.shoulderL.z = base.shoulderL.z + lean * 0.4
        joints.elbowL.y = base.elbowL.y + bob * 0.2 - 20  -- Tight elbow angle
        joints.elbowL.z = base.elbowL.z + armL * 35 + lean
        joints.elbowL.x = base.elbowL.x - 5  -- Elbows in
        joints.handL.y = base.handL.y + bob * 0.1 - 30  -- Hands pump high
        joints.handL.z = base.handL.z + armL * 50 + lean
        joints.handL.x = base.handL.x + 8  -- Hands toward centerline

        joints.shoulderR.y = base.shoulderR.y + bob * 0.3
        joints.shoulderR.z = base.shoulderR.z + lean * 0.4
        joints.elbowR.y = base.elbowR.y + bob * 0.2 - 20
        joints.elbowR.z = base.elbowR.z + armR * 35 + lean
        joints.elbowR.x = base.elbowR.x + 5
        joints.handR.y = base.handR.y + bob * 0.1 - 30
        joints.handR.z = base.handR.z + armR * 50 + lean
        joints.handR.x = base.handR.x - 8

        -- Head stays focused forward
        joints.head.x = base.head.x - hipSway * 0.1
    end
}

animations.dance = {
    name = "Dance",
    speed = 0.5,  -- Full dance loop
    apply = function(joints, base, t)
        local cycle = t * math.pi * 2

        -- Dance has multiple phases within one cycle
        -- Beat 1-2: side step left with arm flourish
        -- Beat 3-4: side step right with opposite arm
        local beat = (t * 4) % 4  -- 0-4 beats per cycle

        -- Bouncy rhythm - double-time bounce
        local bounce = math.abs(math.sin(cycle * 2)) * 8

        -- Side-to-side sway
        local sway = math.sin(cycle) * 15

        -- Groove in the hips - figure-8 motion
        local hipCircleX = math.sin(cycle) * 12
        local hipCircleZ = math.sin(cycle * 2) * 8

        -- Body responds to hip movement
        joints.pelvis.x = base.pelvis.x + hipCircleX
        joints.pelvis.z = base.pelvis.z + hipCircleZ
        joints.pelvis.y = base.pelvis.y + bounce

        joints.hipL.x = base.hipL.x + hipCircleX
        joints.hipR.x = base.hipR.x + hipCircleX
        joints.hipL.y = base.hipL.y + bounce
        joints.hipR.y = base.hipR.y + bounce

        -- Spine creates wave moving up the body
        local spineWave = math.sin(cycle - 0.3) * 10
        local chestWave = math.sin(cycle - 0.6) * 8
        joints.spine.x = base.spine.x + spineWave
        joints.spine.z = base.spine.z + hipCircleZ * 0.7
        joints.spine.y = base.spine.y + bounce * 0.8

        joints.chest.x = base.chest.x + chestWave
        joints.chest.z = base.chest.z + hipCircleZ * 0.4
        joints.chest.y = base.chest.y + bounce * 0.6

        -- Shoulders counter-rotate dramatically
        local shoulderTwist = math.sin(cycle) * 10
        joints.shoulderL.x = base.shoulderL.x + chestWave - shoulderTwist
        joints.shoulderR.x = base.shoulderR.x + chestWave + shoulderTwist
        joints.shoulderL.z = base.shoulderL.z - shoulderTwist * 0.8
        joints.shoulderR.z = base.shoulderR.z + shoulderTwist * 0.8
        joints.shoulderL.y = base.shoulderL.y + bounce * 0.4
        joints.shoulderR.y = base.shoulderR.y + bounce * 0.4

        -- Head grooves with attitude
        joints.neck.x = base.neck.x + chestWave * 0.5
        joints.neck.y = base.neck.y + bounce * 0.3
        joints.head.x = base.head.x + math.sin(cycle + 0.5) * 5
        joints.head.y = base.head.y + bounce * 0.2
        joints.head.z = base.head.z + math.sin(cycle * 2) * 3

        -- ARMS - expressive flowing movements
        -- Left arm: sweeping arc patterns
        local armPhaseL = cycle
        local armSwingL = math.sin(armPhaseL)
        local armLiftL = math.sin(armPhaseL * 2)

        joints.elbowL.x = base.elbowL.x + armSwingL * 20 - 10
        joints.elbowL.y = base.elbowL.y - math.max(0, armLiftL) * 30 + bounce * 0.3
        joints.elbowL.z = base.elbowL.z + math.cos(armPhaseL) * 25

        -- Hand traces flowing path
        joints.handL.x = base.handL.x + armSwingL * 35 - 15
        joints.handL.y = base.handL.y - math.max(0, armLiftL) * 50 + bounce * 0.2
        joints.handL.z = base.handL.z + math.cos(armPhaseL) * 40

        -- Right arm: offset phase for asymmetry
        local armPhaseR = cycle + math.pi * 0.5
        local armSwingR = math.sin(armPhaseR)
        local armLiftR = math.sin(armPhaseR * 2)

        joints.elbowR.x = base.elbowR.x + armSwingR * 20 + 10
        joints.elbowR.y = base.elbowR.y - math.max(0, armLiftR) * 30 + bounce * 0.3
        joints.elbowR.z = base.elbowR.z + math.cos(armPhaseR) * 25

        joints.handR.x = base.handR.x + armSwingR * 35 + 15
        joints.handR.y = base.handR.y - math.max(0, armLiftR) * 50 + bounce * 0.2
        joints.handR.z = base.handR.z + math.cos(armPhaseR) * 40

        -- LEGS - stepping and grooving
        -- Weight shifts side to side
        local weightShift = math.sin(cycle)

        -- Left leg
        local legPhaseL = cycle
        local stepL = math.sin(legPhaseL)
        local liftL = math.max(0, math.sin(legPhaseL * 2)) * 15

        joints.kneeL.x = base.kneeL.x + hipCircleX + stepL * 8
        joints.kneeL.y = base.kneeL.y + bounce - liftL * 0.3
        joints.kneeL.z = base.kneeL.z + stepL * 15

        joints.footL.x = base.footL.x + hipCircleX + stepL * 12
        joints.footL.y = base.footL.y + bounce - liftL
        joints.footL.z = base.footL.z + stepL * 20

        -- Right leg - opposite phase
        local legPhaseR = cycle + math.pi
        local stepR = math.sin(legPhaseR)
        local liftR = math.max(0, math.sin(legPhaseR * 2)) * 15

        joints.kneeR.x = base.kneeR.x + hipCircleX + stepR * 8
        joints.kneeR.y = base.kneeR.y + bounce - liftR * 0.3
        joints.kneeR.z = base.kneeR.z + stepR * 15

        joints.footR.x = base.footR.x + hipCircleX + stepR * 12
        joints.footR.y = base.footR.y + bounce - liftR
        joints.footR.z = base.footR.z + stepR * 20
    end
}

animations.carlton = {
    name = "The Carlton",
    speed = 0.5,  -- Syncs to 4-beat measure like dance
    apply = function(joints, base, t)
        local cycle = t * math.pi * 2

        -- The Carlton: asymmetric arm positions that SWAP on each beat
        -- Arms should move in U/J shapes, not linear interpolation

        -- Raw blend from sine wave
        local rawBlend = (math.sin(cycle) + 1) / 2  -- 0 to 1

        -- Apply smoothstep for snappier, punchier transitions
        local blend = rawBlend * rawBlend * (3 - 2 * rawBlend)

        -- Add slight overshoot at the peaks for that "hit the pose" feel
        local overshoot = math.sin(cycle * 2) * 0.08
        blend = math.max(0, math.min(1, blend + overshoot * (1 - math.abs(rawBlend - 0.5) * 2)))

        -- How much are we in the transition? (0 at key poses, 1 at midpoint)
        local inTransition = math.sin(rawBlend * math.pi)

        -- Arm dip during transition - creates U/J shape path
        local armDip = inTransition * 45

        -- Forward swing during transition - arms come forward as they cross
        local armSwingForward = inTransition * 25

        -- Extra X movement during transition - arms swing wider through the middle
        local armSwingWide = inTransition * 15

        -- Bouncy enthusiasm - double time bounce with extra punch
        local bounce = math.abs(math.sin(cycle * 2)) * 15
        -- Add secondary micro-bounce for snappiness
        local microBounce = math.abs(math.sin(cycle * 4)) * 5

        -- Sway toward the extended arm side
        local sway = math.sin(cycle) * 12

        -- === ARM ELASTIC BOUNCE ===
        -- Add overshoot/bounce when arms arrive at key poses
        -- Phase within each half-cycle (resets at each key pose)
        local halfPhase = (rawBlend * 2) % 1
        -- Decaying bounce that fires after hitting key pose
        local armElastic = math.exp(-halfPhase * 5) * math.sin(halfPhase * math.pi * 6) * 12

        -- === LOWER BODY ===
        -- Extra bouncy with weight shifts
        local totalBounce = bounce + microBounce

        -- Pelvis ROTATES to face the OUT arm direction
        -- blend < 0.5 = facing left (left arm OUT), blend > 0.5 = facing right
        local facingDir = (blend - 0.5) * 2  -- -1 to +1
        local pelvisRotZ = facingDir * 12  -- Z offset for rotation feel

        joints.pelvis.x = base.pelvis.x + sway * 0.4
        joints.pelvis.y = base.pelvis.y + totalBounce
        joints.pelvis.z = base.pelvis.z + facingDir * 5

        joints.hipL.x = base.hipL.x + sway * 0.4
        joints.hipR.x = base.hipR.x + sway * 0.4
        joints.hipL.y = base.hipL.y + totalBounce
        joints.hipR.y = base.hipR.y + totalBounce
        -- Hips rotate with pelvis
        joints.hipL.z = base.hipL.z - pelvisRotZ
        joints.hipR.z = base.hipR.z + pelvisRotZ

        -- === STEPPING LEGS ===
        -- 4 beats per measure, 2 steps per side
        -- Beats 1-2: left foot steps (when left arm OUT)
        -- Beats 3-4: right foot steps (when right arm OUT)
        local beatNum = math.floor(t * 4)  -- 0, 1, 2, 3
        local stepPhase = (t * 4) % 1  -- 0-1 within each beat

        -- Step motion: quick lift and tap
        local stepLift = math.sin(stepPhase * math.pi) * 18
        local stepForward = math.sin(stepPhase * math.pi - math.pi * 0.3) * 12
        local stepOut = math.sin(stepPhase * math.pi) * 5  -- Slight outward motion

        -- Which foot is stepping?
        local leftStepping = (beatNum < 2) and 1 or 0
        local rightStepping = (beatNum >= 2) and 1 or 0

        -- Bouncy knees - more bend on stepping side
        local kneeBendL = (1 - blend) * 12 + microBounce + leftStepping * stepLift * 0.3
        local kneeBendR = blend * 12 + microBounce + rightStepping * stepLift * 0.3

        joints.kneeL.x = base.kneeL.x + sway * 0.25
        joints.kneeL.y = base.kneeL.y + totalBounce - kneeBendL
        joints.kneeL.z = base.kneeL.z - pelvisRotZ * 0.5 + leftStepping * stepForward * 0.4
        joints.kneeR.x = base.kneeR.x + sway * 0.25
        joints.kneeR.y = base.kneeR.y + totalBounce - kneeBendR
        joints.kneeR.z = base.kneeR.z + pelvisRotZ * 0.5 + rightStepping * stepForward * 0.4

        -- Feet with stepping motion
        joints.footL.x = base.footL.x + sway * 0.2 - leftStepping * stepOut
        joints.footL.y = base.footL.y + bounce * 0.3 - leftStepping * stepLift
        joints.footL.z = base.footL.z - pelvisRotZ * 0.7 + leftStepping * stepForward

        joints.footR.x = base.footR.x + sway * 0.2 + rightStepping * stepOut
        joints.footR.y = base.footR.y + bounce * 0.3 - rightStepping * stepLift
        joints.footR.z = base.footR.z + pelvisRotZ * 0.7 + rightStepping * stepForward

        -- === TORSO ===
        -- Twist with pelvis rotation, flowing up the spine
        joints.spine.x = base.spine.x + sway * 0.5
        joints.spine.y = base.spine.y + totalBounce * 0.85
        joints.spine.z = base.spine.z + facingDir * 8  -- Follow pelvis rotation

        joints.chest.x = base.chest.x + sway * 0.6
        joints.chest.y = base.chest.y + totalBounce * 0.7
        joints.chest.z = base.chest.z + facingDir * 10 + inTransition * 8  -- More rotation at chest

        -- Shoulders rotate with body, pump with the beat
        joints.shoulderL.x = base.shoulderL.x + sway * 0.5
        joints.shoulderR.x = base.shoulderR.x + sway * 0.5
        joints.shoulderL.y = base.shoulderL.y + totalBounce * 0.5
        joints.shoulderR.y = base.shoulderR.y + totalBounce * 0.5
        joints.shoulderL.z = base.shoulderL.z - facingDir * 6  -- Counter-rotate slightly
        joints.shoulderR.z = base.shoulderR.z + facingDir * 6

        -- === THE SIGNATURE ARM POSITIONS ===
        -- Reference: One arm OUT to side with elbow below shoulder, forearm points UP
        --            Other arm IN along spine, elbow down, hand at chin

        -- When blend=0: left arm OUT, right arm IN
        -- When blend=1: left arm IN, right arm OUT

        local leftOut = 1 - blend
        local rightOut = blend

        -- === LEFT ARM ===
        -- OUT position: elbow out to SIDE and BELOW shoulder, forearm points STRAIGHT UP
        local L_outElbowX = -45   -- Way out to the side
        local L_outElbowY = -30   -- BELOW shoulder (shoulder is at -72)
        local L_outElbowZ = 5
        local L_outHandX = -50    -- Hand roughly above elbow (slightly more out)
        local L_outHandY = -105   -- Hand way up (forearm nearly vertical)
        local L_outHandZ = 10

        -- IN position: elbow tucked RIGHT NEXT TO body, hand at chin
        -- Base elbowL is at x=-38, so offset of +46 brings it to x≈8 (next to chest)
        -- Base handL is at x=-42, so offset of +52 brings it to x≈10 (in front of face)
        local L_inElbowX = 46     -- Brings elbow right next to chest centerline
        local L_inElbowY = -10    -- Around chest level
        local L_inElbowZ = 20     -- Forward of body
        local L_inHandX = 52      -- Hand in front of face
        local L_inHandY = -80     -- Up at chin level
        local L_inHandZ = 35      -- Well in front of face

        -- Apply U/J shape: dip down during transition, swing forward and wide
        -- Plus elastic bounce when arriving at key poses

        -- Left arm X position - swing wider through the middle of transition
        local leftArmX = (L_outElbowX * leftOut + L_inElbowX * rightOut)
        -- Push arm outward during transition (away from body)
        leftArmX = leftArmX - armSwingWide * (leftOut > rightOut and 1 or -0.3)

        -- Elastic bounce affects Y (vertical pop) - stronger effect when arm is OUT
        local leftElasticY = armElastic * leftOut

        joints.elbowL.x = base.elbowL.x + leftArmX
        joints.elbowL.y = base.elbowL.y + (L_outElbowY * leftOut + L_inElbowY * rightOut) + armDip + totalBounce * 0.2 + leftElasticY * 0.6
        joints.elbowL.z = base.elbowL.z + (L_outElbowZ * leftOut + L_inElbowZ * rightOut) + armSwingForward

        local leftHandX = (L_outHandX * leftOut + L_inHandX * rightOut)
        leftHandX = leftHandX - armSwingWide * 1.2 * (leftOut > rightOut and 1 or -0.3)

        joints.handL.x = base.handL.x + leftHandX
        joints.handL.y = base.handL.y + (L_outHandY * leftOut + L_inHandY * rightOut) + armDip * 1.2 + totalBounce * 0.15 + leftElasticY
        joints.handL.z = base.handL.z + (L_outHandZ * leftOut + L_inHandZ * rightOut) + armSwingForward * 1.3

        -- === RIGHT ARM (mirror of left) ===
        local R_outElbowX = 45    -- Out to right side
        local R_outElbowY = -30
        local R_outElbowZ = 5
        local R_outHandX = 50
        local R_outHandY = -105
        local R_outHandZ = 10

        -- IN position: mirrored - elbow next to body, hand at chin
        -- Base elbowR is at x=38, so offset of -46 brings it to x≈-8 (next to chest)
        -- Base handR is at x=42, so offset of -52 brings it to x≈-10 (in front of face)
        local R_inElbowX = -46    -- Brings elbow right next to chest centerline
        local R_inElbowY = -10    -- Around chest level
        local R_inElbowZ = 20     -- Forward of body
        local R_inHandX = -52     -- Hand in front of face
        local R_inHandY = -80     -- Up at chin level
        local R_inHandZ = 35      -- Well in front of face

        -- Apply U/J shape to right arm (mirrored)
        -- Plus elastic bounce when arriving at key poses
        local rightArmX = (R_outElbowX * rightOut + R_inElbowX * leftOut)
        -- Push arm outward during transition (away from body) - mirrored direction
        rightArmX = rightArmX + armSwingWide * (rightOut > leftOut and 1 or -0.3)

        -- Elastic bounce for right arm - stronger when arm is OUT
        local rightElasticY = armElastic * rightOut

        joints.elbowR.x = base.elbowR.x + rightArmX
        joints.elbowR.y = base.elbowR.y + (R_outElbowY * rightOut + R_inElbowY * leftOut) + armDip + totalBounce * 0.2 + rightElasticY * 0.6
        joints.elbowR.z = base.elbowR.z + (R_outElbowZ * rightOut + R_inElbowZ * leftOut) + armSwingForward

        local rightHandX = (R_outHandX * rightOut + R_inHandX * leftOut)
        rightHandX = rightHandX + armSwingWide * 1.2 * (rightOut > leftOut and 1 or -0.3)

        joints.handR.x = base.handR.x + rightHandX
        joints.handR.y = base.handR.y + (R_outHandY * rightOut + R_inHandY * leftOut) + armDip * 1.2 + totalBounce * 0.15 + rightElasticY
        joints.handR.z = base.handR.z + (R_outHandZ * rightOut + R_inHandZ * leftOut) + armSwingForward * 1.3

        -- === HEAD ===
        -- Head tilts toward the extended arm, bobbing with attitude and extra bounce
        joints.neck.x = base.neck.x + sway * 0.4
        joints.neck.y = base.neck.y + totalBounce * 0.35

        -- Head NOD to the beat (4 nods per measure)
        local beatPhase = (t * 4) % 1  -- 0-1 within each beat
        local nodForward = math.sin(beatPhase * math.pi) * 10  -- Forward on beat
        local nodDown = math.sin(beatPhase * math.pi) * 4  -- Slight down motion on beat

        -- Head bobs with enthusiasm, slight tilt toward extended arm
        local headTilt = math.sin(cycle) * 3  -- Slight rotation feel
        joints.head.x = base.head.x + sway * 0.6 + headTilt
        joints.head.y = base.head.y + totalBounce * 0.25 + nodDown
        joints.head.z = base.head.z + 6 + inTransition * 4 + nodForward  -- Nods forward on beat

        -- Neck follows the nod slightly
        joints.neck.z = base.neck.z + nodForward * 0.4
    end
}

-- List of animation names for cycling
local animationOrder = { "idle", "walk", "run", "dance", "carlton" }
local currentAnimIndex = 1

function love.load()
    love.window.setTitle("Fake 3D - Cube & Stick Figure")
    love.window.setMode(800, 600, { resizable = true, vsync = true })

    initCube()
    initFigure()

    -- Load music if available
    local success, source = pcall(love.audio.newSource, "music.mp3", "stream")
    if success then
        music.source = source
        music.source:setLooping(false)  -- We handle looping manually

        -- Also load as SoundData for beat detection analysis
        print("[Beat Detection] Loading audio for analysis...")
        local soundDataSuccess, soundData = pcall(love.sound.newSoundData, "music.mp3")
        if soundDataSuccess then
            -- Run beat detection
            if analyzeBeatStructure(soundData) then
                -- Apply detected BPM
                music.bpm = beatDetection.detectedBPM
                print(string.format("[Beat Detection] Applied BPM: %d", music.bpm))
            end
            -- Free the sound data after analysis (we use streaming for playback)
            soundData = nil
            collectgarbage("collect")
        else
            print("[Beat Detection] Could not load audio for analysis: " .. tostring(soundData))
        end

        -- Wait for spacebar to start
    else
        print("Could not load music.mp3 - music playback disabled")
    end

    -- Initialize CRT effect
    local shaderSuccess, shader = pcall(love.graphics.newShader, crtShaderSource)
    if shaderSuccess then
        crtShader = shader
        crtCanvas = love.graphics.newCanvas(love.graphics.getWidth(), love.graphics.getHeight())
    else
        print("Could not compile CRT shader: " .. tostring(shader))
        crtEnabled = false
    end
end

-- Handle window resize for CRT canvas
function love.resize(w, h)
    if crtShader then
        crtCanvas = love.graphics.newCanvas(w, h)
    end
end

function initCube()
    local s = cube.size / 2
    cube.vertices = {
        { x = -s, y = -s, z = -s },
        { x =  s, y = -s, z = -s },
        { x =  s, y =  s, z = -s },
        { x = -s, y =  s, z = -s },
        { x = -s, y = -s, z =  s },
        { x =  s, y = -s, z =  s },
        { x =  s, y =  s, z =  s },
        { x = -s, y =  s, z =  s },
    }
    cube.edges = {
        { 1, 2 }, { 2, 3 }, { 3, 4 }, { 4, 1 },
        { 5, 6 }, { 6, 7 }, { 7, 8 }, { 8, 5 },
        { 1, 5 }, { 2, 6 }, { 3, 7 }, { 4, 8 },
    }
end

function initFigure()
    -- STYLIZED PROPORTIONS for dynamic motion
    -- Design principles:
    --   - ~8 heads tall (heroic/fashion hybrid)
    --   - Legs are 55% of total height (elongated for sweeping arcs)
    --   - Arms extend past mid-thigh (expressive reach)
    --   - Wide shoulders (1.8x head width) for strong silhouette
    --   - Narrow hips (1.2x head width) for contrast and readable sway
    --   - Hands/feet rendered larger to emphasize motion endpoints

    local headSize = 18  -- Reference unit

    figure.baseJoints = {
        -- Head & neck (larger head, longer neck for style)
        head       = { x = 0,   y = -108, z = 0 },
        neck       = { x = 0,   y = -78, z = 0 },

        -- Shoulders (wide for dramatic silhouette)
        shoulderL  = { x = -32, y = -72, z = 0 },
        shoulderR  = { x = 32,  y = -72, z = 0 },

        -- Arms (long, especially forearms for expressive arcs)
        elbowL     = { x = -38, y = -38, z = 0 },
        elbowR     = { x = 38,  y = -38, z = 0 },
        handL      = { x = -42, y = 5,   z = 0 },  -- Hands reach past hips
        handR      = { x = 42,  y = 5,   z = 0 },

        -- Torso (tapered - wide chest, narrow waist)
        chest      = { x = 0,   y = -55, z = 0 },
        spine      = { x = 0,   y = -25, z = 0 },  -- Narrow waist point
        pelvis     = { x = 0,   y = -5,  z = 0 },

        -- Hips (narrow for contrast with shoulders)
        hipL       = { x = -12, y = 2,   z = 0 },
        hipR       = { x = 12,  y = 2,   z = 0 },

        -- Legs (elongated - 55% of figure height)
        -- Thighs are long for powerful strides
        kneeL      = { x = -14, y = 50,  z = 0 },
        kneeR      = { x = 14,  y = 50,  z = 0 },

        -- Lower legs slightly longer than thighs (gazelle-like)
        footL      = { x = -16, y = 105, z = 0 },
        footR      = { x = 16,  y = 105, z = 0 },
    }

    -- Store head size for proportional rendering
    figure.headSize = headSize

    figure.joints = {}
    for name, joint in pairs(figure.baseJoints) do
        figure.joints[name] = { x = joint.x, y = joint.y, z = joint.z }
    end

    figure.bones = {
        { "head", "neck" },
        { "neck", "chest" },
        { "chest", "spine" },
        { "spine", "pelvis" },
        { "neck", "shoulderL" },
        { "neck", "shoulderR" },
        { "shoulderL", "shoulderR" },
        { "shoulderL", "elbowL" },
        { "shoulderR", "elbowR" },
        { "elbowL", "handL" },
        { "elbowR", "handR" },
        { "pelvis", "hipL" },
        { "pelvis", "hipR" },
        { "hipL", "hipR" },
        { "hipL", "kneeL" },
        { "hipR", "kneeR" },
        { "kneeL", "footL" },
        { "kneeR", "footR" },
    }
end

local function rotateY(point, angle)
    local cos_a = math.cos(angle)
    local sin_a = math.sin(angle)
    return {
        x = point.x * cos_a + point.z * sin_a,
        y = point.y,
        z = -point.x * sin_a + point.z * cos_a
    }
end

-- Projection mode: "perspective" or "ortho"
local projectionMode = "perspective"

-- Wait for spacebar to start the show
local waitingToStart = true

-- View mode: "ortho" (dual front/side) or "demo" (rotating turntable with effects)
local viewMode = "demo"

-- Ambient background elements
local ambient = {
    elements = {},
    initialized = false,
}

-- Get scale factor based on window size (reference: 600px height)
local function getWindowScale()
    return math.min(love.graphics.getWidth() / 800, love.graphics.getHeight() / 600)
end

local function project(point)
    local screenX, screenY, scale
    local windowScale = getWindowScale()

    -- Subtle camera pulse on beat (zoom in slightly)
    local beatZoom = 1 + music.beatPulse * 0.02

    -- Get camera offset from camera system
    local cameraOffsetX = 0
    local cameraOffsetY = 0
    local cameraZoom = camera.position.z
    if cameraSystem.enabled and viewMode == "demo" then
        cameraOffsetX = cameraSystem.current.offsetX
        cameraOffsetY = cameraSystem.current.offsetY
        cameraZoom = cameraSystem.current.zoom
    end

    if projectionMode == "ortho" then
        -- Orthographic: no perspective, scale with window
        scale = 2.0 * windowScale * beatZoom
        screenX = (point.x + cameraOffsetX) * scale + love.graphics.getWidth() / 2
        screenY = (point.y + cameraOffsetY) * scale + love.graphics.getHeight() / 2
    else
        -- Perspective: objects shrink with distance, scale focal length with window
        local z = point.z + cameraZoom
        if z <= 0 then z = 0.1 end
        scale = (camera.focalLength * windowScale * beatZoom) / z
        screenX = (point.x + cameraOffsetX) * scale + love.graphics.getWidth() / 2
        screenY = (point.y + cameraOffsetY) * scale + love.graphics.getHeight() / 2
    end

    return screenX, screenY, scale
end

-- Spawn a particle at a world position with given velocity
local function spawnParticle(worldPos, velocity, accel, jointName)
    if #particles.list >= particles.maxParticles then
        table.remove(particles.list, 1)  -- Remove oldest
    end

    local speed = math.sqrt(velocity.x^2 + velocity.y^2 + velocity.z^2)
    local accelMag = math.sqrt(accel.x^2 + accel.y^2 + accel.z^2)

    -- Determine particle type based on motion
    local ptype = "fast"
    if accelMag > 500 then
        -- Check if accelerating or decelerating
        -- Dot product of velocity and acceleration
        local dot = velocity.x * accel.x + velocity.y * accel.y + velocity.z * accel.z
        ptype = dot > 0 and "accel" or "decel"
    end

    -- Particle travels opposite to velocity (trail behind)
    local invSpeed = speed > 0 and (1 / speed) or 0
    local trail = {
        x = -velocity.x * invSpeed,
        y = -velocity.y * invSpeed,
        z = -velocity.z * invSpeed
    }

    table.insert(particles.list, {
        -- World position
        x = worldPos.x,
        y = worldPos.y,
        z = worldPos.z,
        -- Velocity for drift (slight trail movement)
        vx = trail.x * 30 + (math.random() - 0.5) * 20,
        vy = trail.y * 30 + (math.random() - 0.5) * 20,
        vz = trail.z * 30 + (math.random() - 0.5) * 20,
        -- Lifetime
        life = particles.baseLifetime * (0.8 + math.random() * 0.4),
        maxLife = particles.baseLifetime,
        -- Visual properties
        size = 3 + speed * 0.02 + math.random() * 2,
        ptype = ptype,
        -- Store original speed for size decay
        speed = speed,
    })
end

-- Update particle physics and lifetime
local function updateParticles(dt)
    local i = 1
    while i <= #particles.list do
        local p = particles.list[i]
        p.life = p.life - dt

        if p.life <= 0 then
            table.remove(particles.list, i)
        else
            -- Drift with slight gravity
            p.x = p.x + p.vx * dt
            p.y = p.y + p.vy * dt + 20 * dt  -- Slight downward drift
            p.z = p.z + p.vz * dt
            -- Dampen velocity
            p.vx = p.vx * 0.95
            p.vy = p.vy * 0.95
            p.vz = p.vz * 0.95
            i = i + 1
        end
    end
end

-- Calculate velocities and spawn particles from fast-moving joints
local function updateMotionParticles(dt, worldJoints)
    -- Skip if dt is too large (e.g., first frame or lag spike)
    if dt > 0.1 then
        for name, pos in pairs(worldJoints) do
            figure.prevWorldJoints[name] = { x = pos.x, y = pos.y, z = pos.z }
            figure.velocities[name] = { x = 0, y = 0, z = 0 }
            figure.prevVelocities[name] = { x = 0, y = 0, z = 0 }
        end
        return
    end

    for name, emitter in pairs(particles.emitters) do
        local curr = worldJoints[name]
        local prev = figure.prevWorldJoints[name]

        if curr and prev then
            -- Calculate velocity
            local vel = {
                x = (curr.x - prev.x) / dt,
                y = (curr.y - prev.y) / dt,
                z = (curr.z - prev.z) / dt
            }
            local speed = math.sqrt(vel.x^2 + vel.y^2 + vel.z^2)

            -- Calculate acceleration
            local prevVel = figure.velocities[name] or { x = 0, y = 0, z = 0 }
            local accel = {
                x = (vel.x - prevVel.x) / dt,
                y = (vel.y - prevVel.y) / dt,
                z = (vel.z - prevVel.z) / dt
            }
            local accelMag = math.sqrt(accel.x^2 + accel.y^2 + accel.z^2)

            -- Store for next frame
            figure.prevVelocities[name] = figure.velocities[name]
            figure.velocities[name] = vel

            -- Spawn particles based on thresholds
            local shouldSpawn = false
            if speed > emitter.velocityThreshold then
                shouldSpawn = true
            end
            if accelMag > emitter.accelThreshold then
                shouldSpawn = true
            end

            -- Rate limiting with some randomness
            if shouldSpawn and math.random() < emitter.rate then
                spawnParticle(curr, vel, accel, name)
            end
        end
    end

    -- Store current positions for next frame
    for name, pos in pairs(worldJoints) do
        figure.prevWorldJoints[name] = { x = pos.x, y = pos.y, z = pos.z }
    end
end

-- Draw particles as sketchy lines thrown off from motion
local function drawParticles()
    if not effects.particles then return end

    for idx, p in ipairs(particles.list) do
        local sx, sy, scale = project(p)
        local lifeRatio = p.life / p.maxLife

        -- Size based on speed and life, capped to prevent overly large particles
        local size = math.min(p.size * scale * lifeRatio * 0.8, 12)

        -- Color based on particle type
        local color = particles.colors[p.ptype] or particles.colors.fast
        local alpha = lifeRatio * 0.9

        -- Draw 2-4 sketchy lines per particle
        local numLines = 2 + (idx % 3)
        local baseSeed = idx * 57 + math.floor(p.life * 100)

        for i = 1, numLines do
            local seed = baseSeed + i * 23

            -- Random angle based on velocity direction plus variation
            local velAngle = math.atan2(p.vy, p.vx)
            local angleVar = math.sin(seed) * 1.2
            local angle = velAngle + angleVar

            -- Line length varies
            local len = size * (0.6 + math.abs(math.sin(seed * 1.3)) * 0.8)

            -- Offset from center
            local offsetX = math.sin(seed * 2.1) * size * 0.4
            local offsetY = math.cos(seed * 1.7) * size * 0.4

            -- Calculate line endpoints
            local dx = math.cos(angle) * len
            local dy = math.sin(angle) * len

            -- Vary thickness
            local thickness = 0.5 + math.abs(math.sin(seed * 0.9)) * 1.5

            -- Slight color variation
            local colorVar = math.sin(seed * 0.4) * 0.15
            love.graphics.setColor(
                color[1] + colorVar,
                color[2] + colorVar * 0.5,
                color[3] - colorVar * 0.3,
                alpha * (0.6 + math.abs(math.sin(seed * 0.7)) * 0.4)
            )

            love.graphics.setLineWidth(thickness)
            love.graphics.line(
                sx + offsetX - dx * 0.5, sy + offsetY - dy * 0.5,
                sx + offsetX + dx * 0.5, sy + offsetY + dy * 0.5
            )
        end
    end
end

-- Spawn beat particles from the main dancer's joints
local function spawnBeatParticles()
    -- Get world positions of joints using current camera angle
    local effectiveAngle = getEffectiveAngle()

    for i = 1, beatParticles.particlesPerBeat do
        -- Pick a random emitter joint
        local jointName = beatParticles.emitters[math.random(1, #beatParticles.emitters)]
        local joint = figure.joints[jointName]
        if joint then
            -- Transform to world space
            local rotated = rotateY(joint, effectiveAngle)
            local worldPos = {
                x = rotated.x + figure.offset.x,
                y = rotated.y + figure.offset.y,
                z = rotated.z + figure.offset.z
            }

            -- Random outward direction (radial from body center)
            local angle = math.random() * math.pi * 2
            local upAngle = (math.random() - 0.5) * math.pi * 0.6  -- Slight vertical spread
            local speed = beatParticles.speed * (0.7 + math.random() * 0.6)

            -- Velocity pointing outward
            local vx = math.cos(angle) * math.cos(upAngle) * speed
            local vy = math.sin(upAngle) * speed * 0.5 - 30  -- Slight upward bias
            local vz = math.sin(angle) * math.cos(upAngle) * speed

            -- Add some velocity based on joint position (radiate from center)
            vx = vx + worldPos.x * 0.5
            vz = vz + worldPos.z * 0.5

            -- Limit particles
            if #beatParticles.list < beatParticles.maxParticles then
                table.insert(beatParticles.list, {
                    x = worldPos.x,
                    y = worldPos.y,
                    z = worldPos.z,
                    vx = vx,
                    vy = vy,
                    vz = vz,
                    life = beatParticles.lifetime,
                    maxLife = beatParticles.lifetime,
                    angle = math.random() * math.pi,  -- Random line angle
                    seed = math.random(1000),         -- For sketchy variation
                })
            end
        end
    end
end

-- Update beat particles
local function updateBeatParticles(dt)
    local i = 1
    while i <= #beatParticles.list do
        local p = beatParticles.list[i]
        p.life = p.life - dt

        if p.life <= 0 then
            table.remove(beatParticles.list, i)
        else
            -- Move outward
            p.x = p.x + p.vx * dt
            p.y = p.y + p.vy * dt
            p.z = p.z + p.vz * dt
            -- Slow down over time
            p.vx = p.vx * 0.92
            p.vy = p.vy * 0.92
            p.vz = p.vz * 0.92
            i = i + 1
        end
    end
end

-- Draw beat particles as sketchy radiating lines
local function drawBeatParticles()
    if not effects.particles then return end

    for idx, p in ipairs(beatParticles.list) do
        local sx, sy, scale = project(p)
        local lifeRatio = p.life / p.maxLife

        -- Fade out and shrink
        local alpha = lifeRatio * 0.55
        local lineLen = beatParticles.lineLength * scale * (0.5 + lifeRatio * 0.5)

        -- Draw 2-3 sketchy lines per particle
        local numLines = 2 + (idx % 2)

        for i = 1, numLines do
            local seed = p.seed + i * 31

            -- Base angle from velocity direction
            local baseAngle = math.atan2(p.vy, p.vx) + p.angle
            -- Add wobble
            local wobble = math.sin(seed + p.life * 10) * 0.4
            local angle = baseAngle + wobble + (i - 1) * 0.3

            -- Line length with variation
            local len = lineLen * (0.7 + math.sin(seed * 1.7) * 0.4)

            -- Wobble offset for sketchiness
            local wobbleX = math.sin(seed * 2.3 + p.life * 15) * beatParticles.wobbleAmount * lifeRatio
            local wobbleY = math.cos(seed * 1.9 + p.life * 12) * beatParticles.wobbleAmount * lifeRatio

            -- Calculate line endpoints
            local dx = math.cos(angle) * len
            local dy = math.sin(angle) * len

            -- Thickness varies
            local thickness = beatParticles.lineWidth * (0.5 + math.sin(seed * 0.8) * 0.5) * lifeRatio

            -- Warm white/yellow color with variation
            local colorSeed = math.sin(seed * 0.5)
            love.graphics.setColor(
                1.0,
                0.9 + colorSeed * 0.1,
                0.7 + colorSeed * 0.2,
                alpha * (0.5 + math.sin(seed * 0.6) * 0.3)
            )

            love.graphics.setLineWidth(math.max(0.5, thickness))
            love.graphics.line(
                sx + wobbleX - dx * 0.5, sy + wobbleY - dy * 0.5,
                sx + wobbleX + dx * 0.5, sy + wobbleY + dy * 0.5
            )
        end
    end
end

-- Update trail history
local function updateTrails(dt, worldJoints)
    if not effects.trails then return end

    trails.timeSinceLastSample = trails.timeSinceLastSample + dt
    if trails.timeSinceLastSample < trails.interval then return end
    trails.timeSinceLastSample = 0

    for _, jointName in ipairs(trails.trackedJoints) do
        local pos = worldJoints[jointName]
        if pos then
            -- Initialize history for this joint if needed
            if not trails.history[jointName] then
                trails.history[jointName] = {}
            end

            -- Add new position to front
            table.insert(trails.history[jointName], 1, {
                x = pos.x, y = pos.y, z = pos.z, age = 0
            })

            -- Trim to max length
            while #trails.history[jointName] > trails.maxLength do
                table.remove(trails.history[jointName])
            end

            -- Age existing points
            for i = 2, #trails.history[jointName] do
                trails.history[jointName][i].age = trails.history[jointName][i].age + trails.interval
            end
        end
    end
end

-- Draw trails as sketchy fading lines
local function drawTrails()
    if not effects.trails then return end

    local trailIdx = 0
    for jointName, history in pairs(trails.history) do
        trailIdx = trailIdx + 1
        if #history >= 2 then
            -- Color based on joint (warm for hands, cool for feet)
            local isHand = jointName == "handL" or jointName == "handR"
            local baseColor = isHand and { 1.0, 0.8, 0.5 } or { 0.5, 0.8, 1.0 }

            for i = 1, #history - 1 do
                local p1 = history[i]
                local p2 = history[i + 1]

                local x1, y1 = project(p1)
                local x2, y2 = project(p2)

                -- Fade based on position in trail (older = more faded)
                local fadeRatio = 1 - (i / #history)
                local alpha = trails.baseAlpha * fadeRatio

                -- Draw 2-3 sketchy lines per trail segment
                local numLines = 2 + ((trailIdx + i) % 2)
                local baseSeed = trailIdx * 100 + i * 31

                for j = 1, numLines do
                    local seed = baseSeed + j * 17

                    -- Offset endpoints for sketchy look
                    local offset1X = math.sin(seed) * 3 * fadeRatio
                    local offset1Y = math.cos(seed * 1.3) * 3 * fadeRatio
                    local offset2X = math.sin(seed * 0.7) * 3 * fadeRatio
                    local offset2Y = math.cos(seed * 1.1) * 3 * fadeRatio

                    -- Vary thickness
                    local thickness = (0.5 + math.abs(math.sin(seed * 0.5)) * 1.5) * fadeRatio

                    -- Color variation
                    local colorVar = math.sin(seed * 0.4) * 0.1
                    love.graphics.setColor(
                        baseColor[1] + colorVar,
                        baseColor[2] + colorVar * 0.5,
                        baseColor[3] - colorVar * 0.3,
                        alpha * (0.5 + math.abs(math.sin(seed * 0.6)) * 0.5)
                    )

                    love.graphics.setLineWidth(thickness)
                    love.graphics.line(
                        x1 + offset1X, y1 + offset1Y,
                        x2 + offset2X, y2 + offset2Y
                    )
                end
            end
        end
    end
end

-- Update motion blur snapshots
local function updateMotionBlur(dt)
    if not effects.motionBlur then return end

    motionBlur.timeSinceLastSnapshot = motionBlur.timeSinceLastSnapshot + dt
    if motionBlur.timeSinceLastSnapshot < motionBlur.interval then return end
    motionBlur.timeSinceLastSnapshot = 0

    -- Create a snapshot of current joint positions
    local snapshot = {
        joints = {},
        angle = getEffectiveAngle(),
        age = 0
    }

    for name, joint in pairs(figure.joints) do
        snapshot.joints[name] = { x = joint.x, y = joint.y, z = joint.z }
    end

    -- Add to front of snapshots
    table.insert(motionBlur.snapshots, 1, snapshot)

    -- Trim to max
    while #motionBlur.snapshots > motionBlur.maxSnapshots do
        table.remove(motionBlur.snapshots)
    end

    -- Age existing snapshots
    for i = 2, #motionBlur.snapshots do
        motionBlur.snapshots[i].age = motionBlur.snapshots[i].age + motionBlur.interval
    end
end

-- Draw motion blur as sketchy ghost figures
local function drawMotionBlur()
    if not effects.motionBlur then return end

    for i, snapshot in ipairs(motionBlur.snapshots) do
        -- Skip the most recent (that's the current frame)
        if i > 1 then
            local fadeRatio = 1 - (i / (#motionBlur.snapshots + 1))
            local alpha = motionBlur.baseAlpha * fadeRatio

            -- Transform snapshot joints to world space
            local transformed = {}
            for name, joint in pairs(snapshot.joints) do
                local rotated = rotateY(joint, snapshot.angle)
                transformed[name] = {
                    x = rotated.x + figure.offset.x,
                    y = rotated.y + figure.offset.y,
                    z = rotated.z + figure.offset.z
                }
            end

            -- Draw ghost bones with sketchy style
            for boneIdx, bone in ipairs(figure.bones) do
                local j1 = transformed[bone[1]]
                local j2 = transformed[bone[2]]
                if j1 and j2 then
                    local x1, y1 = project(j1)
                    local x2, y2 = project(j2)

                    -- Draw 2-3 sketchy lines per ghost bone
                    local numLines = 2 + (boneIdx % 2)
                    local baseSeed = i * 200 + boneIdx * 37

                    for k = 1, numLines do
                        local seed = baseSeed + k * 19

                        -- Offset for sketchy look
                        local offset1X = math.sin(seed) * 2 * fadeRatio
                        local offset1Y = math.cos(seed * 1.2) * 2 * fadeRatio
                        local offset2X = math.sin(seed * 0.8) * 2 * fadeRatio
                        local offset2Y = math.cos(seed * 1.1) * 2 * fadeRatio

                        -- Vary thickness
                        local thickness = (0.4 + math.abs(math.sin(seed * 0.6)) * 1.0) * fadeRatio

                        -- Color variation
                        local colorVar = math.sin(seed * 0.3) * 0.1
                        love.graphics.setColor(
                            0.9 + colorVar,
                            0.6 + colorVar * 0.5,
                            0.4 - colorVar * 0.2,
                            alpha * (0.4 + math.abs(math.sin(seed * 0.5)) * 0.6)
                        )

                        love.graphics.setLineWidth(thickness)
                        love.graphics.line(
                            x1 + offset1X, y1 + offset1Y,
                            x2 + offset2X, y2 + offset2Y
                        )
                    end
                end
            end
        end
    end
end

-- Cycle to next background color
local function cycleBackgroundColor()
    background.currentIndex = background.currentIndex % #background.palette + 1
    background.target = background.palette[background.currentIndex]
end

-- Update background color (lerp towards target)
local function updateBackground(dt)
    local speed = background.lerpSpeed * dt
    background.current.r = background.current.r + (background.target.r - background.current.r) * speed
    background.current.g = background.current.g + (background.target.g - background.current.g) * speed
    background.current.b = background.current.b + (background.target.b - background.current.b) * speed
end

-- Spawn a new pulse ring
local function spawnPulseRing()
    if #pulseRings.rings >= pulseRings.maxRings then
        table.remove(pulseRings.rings, 1)  -- Remove oldest
    end
    table.insert(pulseRings.rings, {
        radius = 0,
        alpha = pulseRings.baseAlpha,
        speed = pulseRings.expandSpeed * (0.9 + math.random() * 0.2),  -- Slight speed variation
        seed = math.random() * 1000,  -- For sketchy variation
    })
end

-- Update pulse rings
local function updatePulseRings(dt)
    local windowScale = getWindowScale()
    -- Ring must expand past the screen diagonal to be fully outside
    local maxRadius = math.sqrt(love.graphics.getWidth()^2 + love.graphics.getHeight()^2) * 0.6

    for i = #pulseRings.rings, 1, -1 do
        local ring = pulseRings.rings[i]
        ring.radius = ring.radius + ring.speed * windowScale * dt
        ring.alpha = math.max(0, ring.alpha - pulseRings.fadeSpeed * dt)

        -- Only remove when fully outside screen
        if ring.radius > maxRadius then
            table.remove(pulseRings.rings, i)
        end
    end
end

-- Draw pulse rings (sketchy style)
local function drawPulseRings()
    local cx = love.graphics.getWidth() / 2
    local cy = love.graphics.getHeight() / 2 + 30  -- Slightly below center
    local windowScale = getWindowScale()
    local wobbleTime = love.timer.getTime() * 0.5

    for _, ring in ipairs(pulseRings.rings) do
        -- Skip if fully faded
        if ring.alpha <= 0 then goto continue end

        -- Draw multiple offset circles for sketchy look
        local numLines = 3
        for i = 1, numLines do
            local seed = ring.seed + i * 47
            local radiusOffset = math.sin(seed) * 4 * windowScale
            local wobble = math.sin(wobbleTime + seed) * 2

            -- Color varies slightly per line
            local colorVar = math.sin(seed * 0.3) * 0.1
            local brightness = 0.4 + ring.alpha * 0.3
            love.graphics.setColor(
                0.5 + colorVar + brightness * 0.3,
                0.45 + colorVar + brightness * 0.2,
                0.35 - colorVar + brightness * 0.1,
                ring.alpha * (0.6 + i * 0.1)
            )

            local thickness = (pulseRings.lineWidth + math.sin(seed * 0.7) * 1.0) * windowScale
            love.graphics.setLineWidth(thickness)

            -- Draw as segmented circle for more sketch feel
            local segments = 48
            local points = {}
            for j = 0, segments do
                local angle = (j / segments) * math.pi * 2
                local segSeed = seed + j * 13
                local segOffset = math.sin(segSeed + wobbleTime) * 3 * windowScale
                local r = ring.radius + radiusOffset + segOffset
                table.insert(points, cx + math.cos(angle) * r + wobble)
                table.insert(points, cy + math.sin(angle) * r * 0.85 + wobble)  -- More circular (0.85 instead of 0.4)
            end
            if #points >= 4 then
                love.graphics.line(points)
            end
        end
        ::continue::
    end
end

-- Initialize ambient background elements
local function initAmbient()
    ambient.elements = {}

    -- Create floating sketch lines
    for i = 1, 15 do
        table.insert(ambient.elements, {
            type = "line",
            x = math.random() * 800,
            y = math.random() * 600,
            vx = (math.random() - 0.5) * 15,
            vy = (math.random() - 0.5) * 10,
            seed = i * 73,
            size = 15 + math.random() * 25,
            rotation = math.random() * math.pi * 2,
            rotSpeed = (math.random() - 0.5) * 0.3,
            depth = 0.3 + math.random() * 0.7,
        })
    end

    -- Create floating asterisks/stars
    for i = 1, 12 do
        table.insert(ambient.elements, {
            type = "asterisk",
            x = math.random() * 800,
            y = math.random() * 600,
            vx = (math.random() - 0.5) * 8,
            vy = (math.random() - 0.5) * 6,
            seed = 1000 + i * 47,
            size = 4 + math.random() * 8,
            rotation = math.random() * math.pi * 2,
            rotSpeed = (math.random() - 0.5) * 0.5,
            depth = 0.2 + math.random() * 0.8,
            beatReactive = math.random() > 0.5,
        })
    end

    -- Create floating squiggles
    for i = 1, 8 do
        table.insert(ambient.elements, {
            type = "squiggle",
            x = math.random() * 800,
            y = math.random() * 600,
            vx = (math.random() - 0.5) * 12,
            vy = (math.random() - 0.5) * 8,
            seed = 2000 + i * 61,
            size = 20 + math.random() * 30,
            rotation = math.random() * math.pi * 2,
            rotSpeed = (math.random() - 0.5) * 0.2,
            depth = 0.4 + math.random() * 0.6,
        })
    end

    -- Create floating geometric shapes (triangles, squares)
    for i = 1, 6 do
        table.insert(ambient.elements, {
            type = "shape",
            shapeType = math.random() > 0.5 and "triangle" or "square",
            x = math.random() * 800,
            y = math.random() * 600,
            vx = (math.random() - 0.5) * 6,
            vy = (math.random() - 0.5) * 5,
            seed = 3000 + i * 83,
            size = 12 + math.random() * 20,
            rotation = math.random() * math.pi * 2,
            rotSpeed = (math.random() - 0.5) * 0.4,
            depth = 0.5 + math.random() * 0.5,
            beatReactive = true,
        })
    end

    -- Create floating dots/circles clusters
    for i = 1, 10 do
        table.insert(ambient.elements, {
            type = "dots",
            x = math.random() * 800,
            y = math.random() * 600,
            vx = (math.random() - 0.5) * 10,
            vy = (math.random() - 0.5) * 7,
            seed = 4000 + i * 37,
            size = 8 + math.random() * 12,
            depth = 0.2 + math.random() * 0.5,
        })
    end

    ambient.initialized = true
end

-- Update ambient elements (positions stored in base 800x600 coordinates)
local function updateAmbient(dt)
    if not ambient.initialized then
        initAmbient()
    end

    -- Use base coordinates for wrapping (scaling happens in draw)
    local baseW, baseH = 800, 600

    for _, elem in ipairs(ambient.elements) do
        elem.x = elem.x + elem.vx * dt * elem.depth
        elem.y = elem.y + elem.vy * dt * elem.depth

        if elem.rotation then
            elem.rotation = elem.rotation + (elem.rotSpeed or 0) * dt
        end

        local margin = 50
        if elem.x < -margin then elem.x = baseW + margin end
        if elem.x > baseW + margin then elem.x = -margin end
        if elem.y < -margin then elem.y = baseH + margin end
        if elem.y > baseH + margin then elem.y = -margin end
    end
end

-- Draw ambient background elements (scaled with window)
local function drawAmbient()
    local wobbleTime = love.timer.getTime() * 0.5

    -- Scale factors for window-responsive drawing
    local winW, winH = love.graphics.getWidth(), love.graphics.getHeight()
    local scaleX = winW / 800
    local scaleY = winH / 600
    local sizeScale = getWindowScale()

    for _, elem in ipairs(ambient.elements) do
        -- Scale position from base 800x600 to current window
        local ex = elem.x * scaleX
        local ey = elem.y * scaleY
        local esize = elem.size * sizeScale

        local baseAlpha = 0.15 + elem.depth * 0.15
        local beatBoost = (elem.beatReactive and music.beatPulse * 0.3) or 0

        if elem.type == "line" then
            local numLines = 2 + (elem.seed % 3)
            for i = 1, numLines do
                local seed = elem.seed + i * 19
                local wobble = math.sin(wobbleTime + seed) * 2 * sizeScale
                local angle = elem.rotation + math.sin(seed) * 0.3
                local len = esize * (0.7 + math.sin(seed * 1.3) * 0.3)
                local dx = math.cos(angle) * len / 2
                local dy = math.sin(angle) * len / 2
                local offX = (math.sin(seed * 2.1) * 3 + wobble)
                local offY = math.cos(seed * 1.7) * 3 * sizeScale
                local thickness = (0.5 + math.abs(math.sin(seed * 0.8)) * 1.0) * sizeScale
                local colorVar = math.sin(seed * 0.4) * 0.1

                love.graphics.setColor(0.5 + colorVar, 0.45 + colorVar, 0.4 - colorVar, baseAlpha)
                love.graphics.setLineWidth(thickness)
                love.graphics.line(ex + offX - dx, ey + offY - dy, ex + offX + dx, ey + offY + dy)
            end

        elseif elem.type == "asterisk" then
            local numSpokes = 3 + (elem.seed % 2)
            local size = esize + beatBoost * 5 * sizeScale
            for i = 1, numSpokes do
                local seed = elem.seed + i * 31
                local angle = elem.rotation + (i - 1) * math.pi / numSpokes + math.sin(seed) * 0.2
                local len = size * (0.6 + math.abs(math.sin(seed * 1.5)) * 0.4)
                local dx = math.cos(angle) * len
                local dy = math.sin(angle) * len
                local offX = math.sin(seed * 2.3) * 1.5 * sizeScale
                local offY = math.cos(seed * 1.9) * 1.5 * sizeScale
                local thickness = (0.4 + math.abs(math.sin(seed * 0.7)) * 0.8) * sizeScale
                local colorVar = math.sin(seed * 0.5) * 0.1

                love.graphics.setColor(0.6 + colorVar + beatBoost, 0.55 + colorVar + beatBoost * 0.8, 0.45 - colorVar, baseAlpha + beatBoost)
                love.graphics.setLineWidth(thickness)
                love.graphics.line(ex + offX - dx, ey + offY - dy, ex + offX + dx, ey + offY + dy)
            end

        elseif elem.type == "squiggle" then
            local numSegments = 6 + (elem.seed % 4)
            local points = {}
            for i = 0, numSegments do
                local t = i / numSegments
                local seed = elem.seed + i * 23
                local baseX = ex + (t - 0.5) * esize
                local waveY = math.sin(t * math.pi * 2 + elem.rotation) * esize * 0.3
                local baseY = ey + waveY
                local offX = math.sin(seed) * 2 * sizeScale
                local offY = math.cos(seed * 1.2) * 2 * sizeScale
                table.insert(points, baseX + offX)
                table.insert(points, baseY + offY)
            end
            local thickness = (0.4 + math.abs(math.sin(elem.seed * 0.5)) * 0.8) * sizeScale
            local colorVar = math.sin(elem.seed * 0.3) * 0.1
            love.graphics.setColor(0.45 + colorVar, 0.4 + colorVar, 0.35 - colorVar, baseAlpha)
            love.graphics.setLineWidth(thickness)
            if #points >= 4 then love.graphics.line(points) end

        elseif elem.type == "shape" then
            local size = esize + beatBoost * 8 * sizeScale
            local numSides = elem.shapeType == "triangle" and 3 or 4
            for line = 1, 2 do
                local lineSeed = elem.seed + line * 41
                local points = {}
                for i = 0, numSides do
                    local angle = elem.rotation + (i / numSides) * math.pi * 2
                    local seed = lineSeed + i * 17
                    local px = ex + math.cos(angle) * size
                    local py = ey + math.sin(angle) * size
                    local offX = math.sin(seed) * 2 * sizeScale
                    local offY = math.cos(seed * 1.3) * 2 * sizeScale
                    table.insert(points, px + offX)
                    table.insert(points, py + offY)
                end
                local thickness = (0.4 + math.abs(math.sin(lineSeed * 0.6)) * 0.8) * sizeScale
                local colorVar = math.sin(lineSeed * 0.4) * 0.1
                love.graphics.setColor(0.5 + colorVar + beatBoost * 0.5, 0.45 + colorVar + beatBoost * 0.4, 0.4 - colorVar, baseAlpha + beatBoost * 0.5)
                love.graphics.setLineWidth(thickness)
                if #points >= 4 then love.graphics.line(points) end
            end

        elseif elem.type == "dots" then
            local numDots = 3 + (elem.seed % 3)
            for i = 1, numDots do
                local seed = elem.seed + i * 29
                local angle = (i / numDots) * math.pi * 2 + math.sin(seed) * 0.5
                local dist = esize * (0.3 + math.abs(math.sin(seed * 1.4)) * 0.7)
                local dotX = ex + math.cos(angle) * dist
                local dotY = ey + math.sin(angle) * dist
                local dotSize = (1 + math.abs(math.sin(seed * 0.8)) * 2) * sizeScale
                local colorVar = math.sin(seed * 0.5) * 0.1
                love.graphics.setColor(0.55 + colorVar, 0.5 + colorVar, 0.4 - colorVar, baseAlpha)
                love.graphics.circle("fill", dotX, dotY, dotSize)
            end
        end
    end
end

-- Update BPM timing system
local function updateMusic(dt)
    local beatDuration = 60 / music.bpm  -- Seconds per beat
    local measureDuration = beatDuration * music.beatsPerMeasure

    -- If music is playing and we have beat detection, sync to audio position
    if music.source and music.playing and beatDetection.analyzed then
        local pos = music.source:tell()
        -- Adjust for detected first beat offset
        local adjustedPos = pos - beatDetection.firstBeatTime
        -- Set beat time directly from audio position
        music.beatTime = adjustedPos
    else
        -- Fallback: advance beat time independently
        music.beatTime = music.beatTime + dt
    end

    -- Calculate phases
    music.beatPhase = (music.beatTime / beatDuration) % 1
    if music.beatPhase < 0 then music.beatPhase = music.beatPhase + 1 end
    music.measurePhase = (music.beatTime / measureDuration) % 1
    if music.measurePhase < 0 then music.measurePhase = music.measurePhase + 1 end

    -- Detect beat crossing for visual pulse (only when show has started)
    if music.beatPhase < music.lastBeatPhase and not waitingToStart then
        music.beatPulse = 1.0  -- Trigger pulse on beat
        -- Spawn radial pulse ring on beat
        if pulseRings.spawnOnBeat then
            spawnPulseRing()
        end
        -- Spawn beat particles from dancer
        spawnBeatParticles()
        -- Cycle background color on beat
        cycleBackgroundColor()
        -- Camera system beat counting
        if cameraSystem.enabled then
            cameraSystem.beatCount = cameraSystem.beatCount + 1
            if cameraSystem.beatCount >= cameraSystem.beatsPerShot then
                switchCameraShot()
            end
        end
        -- Choreography system - switch animations on beat
        if choreography.enabled then
            choreography.beatsInCurrentSection = choreography.beatsInCurrentSection + 1
            local section = choreography.sequence[choreography.currentIndex]
            if section and choreography.beatsInCurrentSection >= section.beats then
                -- Move to next section
                choreography.currentIndex = choreography.currentIndex + 1
                choreography.beatsInCurrentSection = 0
                local nextSection = choreography.sequence[choreography.currentIndex]
                if nextSection then
                    figure.currentAnim = nextSection.anim
                    figure.animTime = 0
                end
            end
        end
    end
    music.lastBeatPhase = music.beatPhase

    -- Decay the beat pulse
    music.beatPulse = math.max(0, music.beatPulse - dt * 4)

    -- Handle audio loop
    if music.source and music.playing then
        local pos = music.source:tell()
        if pos >= music.loopEnd or not music.source:isPlaying() then
            music.source:seek(music.loopStart)
            if not music.source:isPlaying() then
                music.source:play()
            end
        end
    end

    -- Clean up old tap times
    local currentTime = love.timer.getTime()
    local i = 1
    while i <= #music.tapTimes do
        if currentTime - music.tapTimes[i] > music.tapWindow then
            table.remove(music.tapTimes, i)
        else
            i = i + 1
        end
    end
end

-- Handle tap tempo input
local function tapTempo()
    local currentTime = love.timer.getTime()
    table.insert(music.tapTimes, currentTime)

    -- Keep only recent taps
    while #music.tapTimes > music.maxTaps do
        table.remove(music.tapTimes, 1)
    end

    -- Calculate BPM from tap intervals
    if #music.tapTimes >= 2 then
        local totalInterval = 0
        local intervalCount = 0

        for i = 2, #music.tapTimes do
            local interval = music.tapTimes[i] - music.tapTimes[i - 1]
            -- Only count reasonable intervals (30-300 BPM range)
            if interval > 0.2 and interval < 2.0 then
                totalInterval = totalInterval + interval
                intervalCount = intervalCount + 1
            end
        end

        if intervalCount > 0 then
            local avgInterval = totalInterval / intervalCount
            music.bpm = math.floor(60 / avgInterval + 0.5)
            music.bpm = math.max(30, math.min(300, music.bpm))  -- Clamp to valid range

            -- Reset beat time to align with tap
            music.beatTime = 0
        end
    end
end

-- Get animation time - either from internal clock or BPM sync
local function getAnimationTime(animName)
    if animName == "dance" and music.syncEnabled then
        -- Dance syncs to measure phase (4 beats = 1 dance cycle)
        return music.measurePhase
    else
        -- Other animations use their own timing
        return figure.animTime % 1
    end
end

local function animateFigure(dt)
    local anim = animations[figure.currentAnim]
    if not anim then return end

    -- Get animation time - either BPM-synced or internal
    local t
    local isDanceAnim = figure.currentAnim == "dance" or figure.currentAnim == "carlton"
    if isDanceAnim and music.syncEnabled then
        -- Dance animations sync directly to measure phase
        t = music.measurePhase
    else
        -- Other animations use their own speed-based timing
        figure.animTime = figure.animTime + dt * anim.speed
        t = figure.animTime % 1
    end

    -- Reset to base pose
    for name, base in pairs(figure.baseJoints) do
        figure.joints[name].x = base.x
        figure.joints[name].y = base.y
        figure.joints[name].z = base.z
    end

    -- Apply current animation
    anim.apply(figure.joints, figure.baseJoints, t)
end

function love.update(dt)
    -- Update music/BPM timing
    updateMusic(dt)

    -- Update camera system
    updateCameraSystem(dt)

    cube.angle = cube.angle + cube.rotationSpeed * dt

    -- Rotate figure only in demo mode when camera system is disabled
    if viewMode == "demo" and not cameraSystem.enabled then
        figure.angle = figure.angle + 0.3 * dt  -- Slow turntable rotation
    end

    animateFigure(dt)

    -- Calculate world-space joint positions for effects
    -- Use camera angle when camera system is active
    local effectiveAngle = getEffectiveAngle()
    local worldJoints = {}
    for name, joint in pairs(figure.joints) do
        local rotated = rotateY(joint, effectiveAngle)
        worldJoints[name] = {
            x = rotated.x + figure.offset.x,
            y = rotated.y + figure.offset.y,
            z = rotated.z + figure.offset.z
        }
    end

    -- Update all effects
    updateMotionParticles(dt, worldJoints)
    updateParticles(dt)
    updateBeatParticles(dt)
    updateTrails(dt, worldJoints)
    updateMotionBlur(dt)

    -- Update ambient background and pulse rings (demo mode only)
    if viewMode == "demo" then
        updateAmbient(dt)
        updatePulseRings(dt)
        updateBackground(dt)
    end
end

local function drawCube()
    local transformed = {}
    for i, vertex in ipairs(cube.vertices) do
        local rotated = rotateY(vertex, cube.angle)
        rotated.x = rotated.x + cube.offset.x
        rotated.y = rotated.y + cube.offset.y
        rotated.z = rotated.z + cube.offset.z
        transformed[i] = rotated
    end

    love.graphics.setLineWidth(2)
    for _, edge in ipairs(cube.edges) do
        local p1 = transformed[edge[1]]
        local p2 = transformed[edge[2]]
        local x1, y1, scale1 = project(p1)
        local x2, y2, scale2 = project(p2)

        local avgScale = (scale1 + scale2) / 2
        local brightness = math.min(1, avgScale * 0.8)
        love.graphics.setColor(0.3 + brightness * 0.7, 0.5 + brightness * 0.5, 0.9)
        love.graphics.line(x1, y1, x2, y2)
    end

    for _, vertex in ipairs(transformed) do
        local x, y, scale = project(vertex)
        local radius = math.max(2, scale * 4)
        love.graphics.setColor(1, 1, 1)
        love.graphics.circle("fill", x, y, radius)
    end
end

-- Draw figure at a specific position with optional Y rotation
local function drawFigureAt(offsetX, offsetY, angle, label)
    local transformed = {}
    for name, joint in pairs(figure.joints) do
        local rotated = rotateY(joint, angle)
        transformed[name] = {
            x = rotated.x + offsetX,
            y = rotated.y + offsetY,
            z = rotated.z
        }
    end

    -- Draw label
    if label then
        love.graphics.setColor(0.7, 0.7, 0.7)
        local windowScale = getWindowScale()
        local labelX, labelY = project({ x = offsetX, y = -130 + offsetY, z = 0 })
        love.graphics.print(label, labelX - 25 * windowScale, labelY - 20 * windowScale)
    end

    -- Draw bones with hand-drawn style: multiple slightly offset lines
    local baseWidth = 2  -- Thinner base for more lines
    local wobbleTime = love.timer.getTime() * 0.5  -- Subtle time-based wobble

    for boneIdx, bone in ipairs(figure.bones) do
        local j1 = transformed[bone[1]]
        local j2 = transformed[bone[2]]
        local x1, y1, scale1 = project(j1)
        local x2, y2, scale2 = project(j2)

        local avgScale = (scale1 + scale2) / 2
        local brightness = math.min(1, avgScale * 0.8)

        -- Hand-drawn effect: draw 5-7 slightly offset lines per bone
        local numLines = 5 + (boneIdx % 3)  -- Varies by bone: 5, 6, or 7 lines

        for i = 1, numLines do
            -- Stable pseudo-random offsets based on bone index and line number
            local seed = boneIdx * 100 + i * 17
            -- Add tiny wobble for organic feel
            local wobble = math.sin(wobbleTime + seed) * 0.3

            local offsetX1 = math.sin(seed) * 2.5 + wobble
            local offsetY1 = math.cos(seed * 1.3) * 2.5 + wobble
            local offsetX2 = math.sin(seed * 0.7) * 2.5 - wobble
            local offsetY2 = math.cos(seed * 1.1) * 2.5 - wobble

            -- Vary thickness (thinner lines, 20-80% of base)
            local thicknessFactor = 0.2 + math.abs(math.sin(seed * 0.5)) * 0.6
            local thickness = baseWidth * thicknessFactor

            -- Slight color variation for each stroke
            local colorVar = math.sin(seed * 0.3) * 0.08
            love.graphics.setColor(
                0.9 + colorVar,
                0.5 + brightness * 0.4 + colorVar * 0.5,
                0.3 + brightness * 0.3 - colorVar * 0.3
            )

            love.graphics.setLineWidth(thickness)
            love.graphics.line(x1 + offsetX1, y1 + offsetY1, x2 + offsetX2, y2 + offsetY2)
        end
    end

    -- Joint size multipliers for stylized emphasis
    local jointSizes = {
        head = 5.0,       -- Large expressive head
        neck = 0.6,
        shoulderL = 0.9, shoulderR = 0.9,
        elbowL = 0.7, elbowR = 0.7,
        handL = 1.4, handR = 1.4,      -- Large hands for expression
        chest = 0.8,
        spine = 0.5,      -- Thin waist
        pelvis = 0.7,
        hipL = 0.6, hipR = 0.6,
        kneeL = 0.7, kneeR = 0.7,
        footL = 1.3, footR = 1.3,      -- Large feet for grounding
    }

    -- Draw joints as 3D asterisks (criss-crossing lines)
    local jointIdx = 0
    for name, joint in pairs(transformed) do
        jointIdx = jointIdx + 1
        local x, y, scale = project(joint)
        local sizeMultiplier = jointSizes[name] or 1.0
        local radius = math.max(2, scale * 5 * sizeMultiplier)

        -- Color based on joint type
        local r, g, b
        if name == "head" then
            r, g, b = 1, 0.85, 0.7
        elseif name == "handL" or name == "handR" then
            r, g, b = 1, 0.9, 0.85
        elseif name == "footL" or name == "footR" then
            r, g, b = 0.95, 0.85, 0.75
        else
            r, g, b = 1, 0.9, 0.8
        end

        -- Draw 3D asterisk: 3-4 lines crossing through center at various angles
        local numSpokes = 3 + (jointIdx % 2)  -- 3 or 4 spokes
        local baseSeed = jointIdx * 73

        for i = 1, numSpokes do
            local seed = baseSeed + i * 31
            -- Base angle evenly distributed, with slight random offset
            local baseAngle = (i - 1) * math.pi / numSpokes
            local angleOffset = math.sin(seed) * 0.2
            local angle = baseAngle + angleOffset

            -- Slight length variation
            local lengthVar = 0.8 + math.abs(math.sin(seed * 1.7)) * 0.4
            local len = radius * lengthVar

            -- Calculate line endpoints
            local dx = math.cos(angle) * len
            local dy = math.sin(angle) * len

            -- Small offset from center for hand-drawn feel
            local centerOffX = math.sin(seed * 2.3) * 1.5
            local centerOffY = math.cos(seed * 1.9) * 1.5

            -- Vary thickness
            local thickness = 1 + math.abs(math.sin(seed * 0.8)) * 1.2

            -- Slight color variation per spoke
            local colorVar = math.sin(seed * 0.4) * 0.1
            love.graphics.setColor(r + colorVar, g + colorVar * 0.5, b - colorVar * 0.3)
            love.graphics.setLineWidth(thickness)
            love.graphics.line(
                x + centerOffX - dx, y + centerOffY - dy,
                x + centerOffX + dx, y + centerOffY + dy
            )
        end

        -- Head gets extra detail - additional outer ring of spokes
        if name == "head" then
            for i = 1, 4 do
                local seed = baseSeed + 100 + i * 23
                local angle = (i - 1) * math.pi / 4 + math.pi / 8 + math.sin(seed) * 0.15
                local len = radius * 0.9
                local dx = math.cos(angle) * len
                local dy = math.sin(angle) * len

                local thickness = 0.8 + math.abs(math.sin(seed * 0.6)) * 0.8
                local colorVar = math.sin(seed * 0.5) * 0.08
                love.graphics.setColor(0.8 + colorVar, 0.5 + colorVar, 0.3 - colorVar)
                love.graphics.setLineWidth(thickness)
                love.graphics.line(x - dx, y - dy, x + dx, y + dy)
            end
        end
    end
end

-- Draw a sketchy rotating platform with height that pulses to the beat
local function drawPlatform(angle, centerY)
    local platformRadius = 80
    local baseHeight = 25  -- Base platform thickness
    local wobbleTime = love.timer.getTime() * 0.3

    -- Beat pulse effect
    local beatPulse = music.beatPulse * 8  -- Expand on beat
    local platformHeight = baseHeight + beatPulse
    local radiusPulse = platformRadius + music.beatPulse * 5  -- Slight radius pulse too

    local topY = centerY + 115  -- Top surface at foot level
    local bottomY = topY + platformHeight  -- Bottom of platform

    -- Draw bottom ellipse first (back edge)
    local function drawEllipseRing(y, radius, brightness, alpha, seedOffset)
        local numSegments = 24
        local numLines = 3

        for line = 1, numLines do
            local lineSeed = seedOffset + line * 37
            local points = {}

            for seg = 0, numSegments do
                local segAngle = (seg / numSegments) * math.pi * 2 + angle
                local seed = lineSeed + seg * 13

                local px = math.cos(segAngle) * radius
                local pz = math.sin(segAngle) * radius * 0.35

                local wobble = math.sin(wobbleTime + seed) * 0.5
                local offsetX = math.sin(seed) * 2 + wobble
                local offsetZ = math.cos(seed * 1.3) * 1 + wobble

                local point = {
                    x = px + offsetX + figure.offset.x,
                    y = y,
                    z = pz + offsetZ + figure.offset.z
                }
                local sx, sy = project(point)
                table.insert(points, sx)
                table.insert(points, sy)
            end

            local thickness = 0.4 + math.abs(math.sin(lineSeed * 0.5)) * 1.2
            local colorVar = math.sin(lineSeed * 0.4) * 0.08

            love.graphics.setColor(
                brightness + colorVar,
                brightness * 0.9 + colorVar * 0.5,
                brightness * 0.7 - colorVar * 0.3,
                alpha
            )

            love.graphics.setLineWidth(thickness)
            if #points >= 4 then
                love.graphics.line(points)
            end
        end
    end

    -- Draw vertical side lines (the cylinder walls)
    local numVerticals = 16
    for i = 1, numVerticals do
        local vertAngle = (i / numVerticals) * math.pi * 2 + angle

        -- Only draw front-facing verticals (where z > 0 after rotation)
        local testZ = math.sin(vertAngle) * 0.35
        if testZ > -0.1 then  -- Front half plus a bit
            local baseSeed = 800 + i * 53

            for line = 1, 2 do
                local seed = baseSeed + line * 29

                local px = math.cos(vertAngle) * radiusPulse
                local pz = math.sin(vertAngle) * radiusPulse * 0.35

                local offX = math.sin(seed) * 1.5
                local offZ = math.cos(seed * 1.2) * 0.8

                local topPoint = {
                    x = px + offX + figure.offset.x,
                    y = topY,
                    z = pz + offZ + figure.offset.z
                }
                local bottomPoint = {
                    x = px + offX + math.sin(seed * 0.7) * 1 + figure.offset.x,
                    y = bottomY,
                    z = pz + offZ + math.cos(seed * 0.9) * 0.5 + figure.offset.z
                }

                local x1, y1 = project(topPoint)
                local x2, y2 = project(bottomPoint)

                local thickness = 0.3 + math.abs(math.sin(seed * 0.6)) * 1.0
                local colorVar = math.sin(seed * 0.4) * 0.06
                local depthFade = 0.5 + testZ * 0.5  -- Fade based on depth

                love.graphics.setColor(
                    0.3 + colorVar,
                    0.28 + colorVar * 0.5,
                    0.22 - colorVar * 0.3,
                    0.6 * depthFade
                )
                love.graphics.setLineWidth(thickness)
                love.graphics.line(x1, y1, x2, y2)
            end
        end
    end

    -- Draw bottom ellipse (darker)
    drawEllipseRing(bottomY, radiusPulse, 0.25, 0.5, 200)

    -- Draw top surface with concentric rings
    for ring = 1, 3 do
        local ringRadius = radiusPulse * (0.4 + ring * 0.22)
        local brightness = 0.35 + ring * 0.08 + music.beatPulse * 0.15  -- Brighten on beat
        local alpha = 0.7 - ring * 0.1
        drawEllipseRing(topY, ringRadius, brightness, alpha, ring * 100)
    end

    -- Add radial sketch lines on top surface
    local numRadials = 8
    for i = 1, numRadials do
        local radialAngle = (i / numRadials) * math.pi * 2 + angle
        local baseSeed = 500 + i * 47

        for line = 1, 2 do
            local seed = baseSeed + line * 23

            local innerR = radiusPulse * 0.2
            local outerR = radiusPulse * (0.85 + math.sin(seed) * 0.15)

            local innerX = math.cos(radialAngle) * innerR
            local innerZ = math.sin(radialAngle) * innerR * 0.35
            local outerX = math.cos(radialAngle) * outerR
            local outerZ = math.sin(radialAngle) * outerR * 0.35

            local off1X = math.sin(seed) * 2
            local off1Z = math.cos(seed * 1.2) * 1
            local off2X = math.sin(seed * 0.8) * 2
            local off2Z = math.cos(seed * 1.1) * 1

            local p1 = { x = innerX + off1X + figure.offset.x, y = topY, z = innerZ + off1Z + figure.offset.z }
            local p2 = { x = outerX + off2X + figure.offset.x, y = topY, z = outerZ + off2Z + figure.offset.z }

            local x1, y1 = project(p1)
            local x2, y2 = project(p2)

            local thickness = 0.3 + math.abs(math.sin(seed * 0.6)) * 0.8
            local colorVar = math.sin(seed * 0.3) * 0.06
            love.graphics.setColor(
                0.4 + colorVar + music.beatPulse * 0.1,
                0.35 + colorVar + music.beatPulse * 0.08,
                0.28 - colorVar,
                0.4
            )
            love.graphics.setLineWidth(thickness)
            love.graphics.line(x1, y1, x2, y2)
        end
    end
end

-- Draw a single dancer with optional position offset, color shift, and animation variation
local function drawDancer(posOffset, colorShift, scaleMultiplier, seedOffset, animVariation)
    posOffset = posOffset or { x = 0, z = 0 }
    colorShift = colorShift or { r = 0, g = 0, b = 0 }
    scaleMultiplier = scaleMultiplier or 1.0
    seedOffset = seedOffset or 0
    animVariation = animVariation or { phaseOffset = 0, poseWobble = 0, wobbleSpeed = 1 }

    local time = love.timer.getTime()
    local wobbleTime = time * (animVariation.wobbleSpeed or 1)
    local poseWobble = animVariation.poseWobble or 0

    -- Joint-specific wobble amounts (extremities wobble more)
    local jointWobbleScale = {
        head = 0.6, neck = 0.4,
        shoulderL = 0.5, shoulderR = 0.5,
        elbowL = 0.8, elbowR = 0.8,
        handL = 1.2, handR = 1.2,
        chest = 0.3, spine = 0.2, pelvis = 0.2,
        hipL = 0.3, hipR = 0.3,
        kneeL = 0.6, kneeR = 0.6,
        footL = 0.9, footR = 0.9,
    }

    -- Transform joints to world space with position offset and animation variation
    local transformed = {}
    local jointIdx = 0
    for name, joint in pairs(figure.joints) do
        jointIdx = jointIdx + 1

        -- Calculate pose wobble for this joint
        local wobbleScale = (jointWobbleScale[name] or 1.0) * poseWobble * 8
        local seed = jointIdx * 47 + (seedOffset or 0) * 1000
        local wobbleX = math.sin(wobbleTime * 1.7 + seed) * wobbleScale
        local wobbleY = math.sin(wobbleTime * 2.3 + seed * 1.3) * wobbleScale * 0.5
        local wobbleZ = math.cos(wobbleTime * 1.9 + seed * 0.7) * wobbleScale

        -- Apply scale and wobble to joint positions
        local scaledJoint = {
            x = (joint.x + wobbleX) * scaleMultiplier,
            y = (joint.y + wobbleY) * scaleMultiplier,
            z = (joint.z + wobbleZ) * scaleMultiplier
        }
        local rotated = rotateY(scaledJoint, getEffectiveAngle())
        transformed[name] = {
            x = rotated.x + figure.offset.x + posOffset.x,
            y = rotated.y + figure.offset.y,
            z = rotated.z + figure.offset.z + posOffset.z
        }
    end

    -- Draw bones with hand-drawn style
    local baseWidth = 2 * scaleMultiplier
    local sketchWobbleTime = time * 0.5  -- Slower wobble for sketch line variation

    for boneIdx, bone in ipairs(figure.bones) do
        local j1 = transformed[bone[1]]
        local j2 = transformed[bone[2]]
        local x1, y1, scale1 = project(j1)
        local x2, y2, scale2 = project(j2)

        local avgScale = (scale1 + scale2) / 2
        local brightness = math.min(1, avgScale * 0.8)

        local numLines = 5 + (boneIdx % 3)

        for i = 1, numLines do
            local seed = boneIdx * 100 + i * 17 + seedOffset * 1000
            local wobble = math.sin(sketchWobbleTime + seed) * 0.3

            local offsetX1 = math.sin(seed) * 2.5 + wobble
            local offsetY1 = math.cos(seed * 1.3) * 2.5 + wobble
            local offsetX2 = math.sin(seed * 0.7) * 2.5 - wobble
            local offsetY2 = math.cos(seed * 1.1) * 2.5 - wobble

            local thicknessFactor = 0.2 + math.abs(math.sin(seed * 0.5)) * 0.6
            local thickness = baseWidth * thicknessFactor

            local colorVar = math.sin(seed * 0.3) * 0.08
            local r = math.max(0, math.min(1, 0.9 + colorVar + colorShift.r))
            local g = math.max(0, math.min(1, 0.5 + brightness * 0.4 + colorVar * 0.5 + colorShift.g))
            local b = math.max(0, math.min(1, 0.3 + brightness * 0.3 - colorVar * 0.3 + colorShift.b))
            love.graphics.setColor(r, g, b)

            love.graphics.setLineWidth(thickness)
            love.graphics.line(x1 + offsetX1, y1 + offsetY1, x2 + offsetX2, y2 + offsetY2)
        end
    end

    -- Draw joints as asterisks
    local jointSizes = {
        head = 5.0, neck = 0.6,
        shoulderL = 0.9, shoulderR = 0.9,
        elbowL = 0.7, elbowR = 0.7,
        handL = 1.4, handR = 1.4,
        chest = 0.8, spine = 0.5, pelvis = 0.7,
        hipL = 0.6, hipR = 0.6,
        kneeL = 0.7, kneeR = 0.7,
        footL = 1.3, footR = 1.3,
    }

    local jointIdx = 0
    for name, joint in pairs(transformed) do
        jointIdx = jointIdx + 1
        local x, y, scale = project(joint)
        local sizeMultiplier = jointSizes[name] or 1.0
        local radius = math.max(2, scale * 5 * sizeMultiplier)

        local baseR, baseG, baseB
        if name == "head" then
            baseR, baseG, baseB = 1, 0.85, 0.7
        elseif name == "handL" or name == "handR" then
            baseR, baseG, baseB = 1, 0.9, 0.85
        elseif name == "footL" or name == "footR" then
            baseR, baseG, baseB = 0.95, 0.85, 0.75
        else
            baseR, baseG, baseB = 1, 0.9, 0.8
        end

        local numSpokes = 3 + (jointIdx % 2)
        local baseSeed = jointIdx * 73 + seedOffset * 500

        for i = 1, numSpokes do
            local seed = baseSeed + i * 31
            local baseAngle = (i - 1) * math.pi / numSpokes
            local angleOffset = math.sin(seed) * 0.2
            local angle = baseAngle + angleOffset

            local lengthVar = 0.8 + math.abs(math.sin(seed * 1.7)) * 0.4
            local len = radius * lengthVar

            local dx = math.cos(angle) * len
            local dy = math.sin(angle) * len

            local centerOffX = math.sin(seed * 2.3) * 1.5
            local centerOffY = math.cos(seed * 1.9) * 1.5

            local thickness = 1 + math.abs(math.sin(seed * 0.8)) * 1.2

            local colorVar = math.sin(seed * 0.4) * 0.1
            local r = math.max(0, math.min(1, baseR + colorVar + colorShift.r))
            local g = math.max(0, math.min(1, baseG + colorVar * 0.5 + colorShift.g))
            local b = math.max(0, math.min(1, baseB - colorVar * 0.3 + colorShift.b))
            love.graphics.setColor(r, g, b)
            love.graphics.setLineWidth(thickness)
            love.graphics.line(
                x + centerOffX - dx, y + centerOffY - dy,
                x + centerOffX + dx, y + centerOffY + dy
            )
        end

        if name == "head" then
            for i = 1, 4 do
                local seed = baseSeed + 100 + i * 23
                local angle = (i - 1) * math.pi / 4 + math.pi / 8 + math.sin(seed) * 0.15
                local len = radius * 0.9
                local dx = math.cos(angle) * len
                local dy = math.sin(angle) * len

                local thickness = 0.8 + math.abs(math.sin(seed * 0.6)) * 0.8
                local colorVar = math.sin(seed * 0.5) * 0.08
                local r = math.max(0, math.min(1, 0.8 + colorVar + colorShift.r * 0.5))
                local g = math.max(0, math.min(1, 0.5 + colorVar + colorShift.g * 0.5))
                local b = math.max(0, math.min(1, 0.3 - colorVar + colorShift.b * 0.5))
                love.graphics.setColor(r, g, b)
                love.graphics.setLineWidth(thickness)
                love.graphics.line(x - dx, y - dy, x + dx, y + dy)
            end
        end
    end
end

-- Draw the figure with motion effects for demo mode
local function drawFigureWithEffects()
    -- Draw radial pulse rings (behind everything)
    drawPulseRings()

    -- Draw ambient background elements
    drawAmbient()

    -- Draw platform (behind figure)
    drawPlatform(getEffectiveAngle(), figure.offset.y)

    -- Draw motion blur
    drawMotionBlur()

    -- Draw trails
    drawTrails()

    -- Draw backup dancers first (they're behind the main dancer)
    for i, dancer in ipairs(backupDancers) do
        local animVar = {
            phaseOffset = dancer.phaseOffset or 0,
            poseWobble = dancer.poseWobble or 0,
            wobbleSpeed = dancer.wobbleSpeed or 1,
        }
        drawDancer(dancer.offset, dancer.colorShift, dancer.scale, dancer.sketchVariation, animVar)
    end

    -- Draw main dancer
    drawDancer(nil, nil, nil, nil)

    -- Draw particles on top
    drawParticles()
    drawBeatParticles()
end

function love.draw()
    -- Begin rendering to CRT canvas if enabled
    if crtEnabled and crtCanvas then
        love.graphics.setCanvas(crtCanvas)
        love.graphics.clear(background.current.r, background.current.g, background.current.b, 1)
    else
        love.graphics.setBackgroundColor(background.current.r, background.current.g, background.current.b)
    end

    if viewMode == "ortho" then
        -- Dual view: Front and Side (no rotation)
        -- Position figures at 25% and 75% of window width
        local offsetX = love.graphics.getWidth() * 0.22
        local offsetY = love.graphics.getHeight() * 0.05
        drawFigureAt(-offsetX, offsetY, 0, "FRONT")
        drawFigureAt(offsetX, offsetY, math.pi / 2, "SIDE")
    else
        -- Demo mode: centered figure on rotating turntable with effects
        -- Center the figure
        figure.offset.x = 0
        figure.offset.y = 0
        drawFigureWithEffects()
    end

    -- UI - Controls
    love.graphics.setColor(0.6, 0.6, 0.6)
    love.graphics.print("Arrow keys: rotation | +/-: zoom | Space: pause | Tab: animation | ESC: quit", 10, 10)

    -- Current animation display
    local anim = animations[figure.currentAnim]
    love.graphics.setColor(1, 0.8, 0.5)
    love.graphics.print("Animation: " .. anim.name, 10, 30)

    -- Effect toggles status
    local function statusColor(enabled)
        if enabled then
            return 0.4, 1.0, 0.5  -- Green
        else
            return 0.6, 0.4, 0.4  -- Dim red
        end
    end

    love.graphics.setColor(0.7, 0.7, 0.7)
    love.graphics.print("Effects (toggle keys):", 10, 55)

    love.graphics.setColor(statusColor(effects.particles))
    love.graphics.print("[1] Particles: " .. (effects.particles and "ON" or "OFF"), 10, 75)

    love.graphics.setColor(statusColor(effects.trails))
    love.graphics.print("[2] Trails: " .. (effects.trails and "ON" or "OFF"), 10, 95)

    love.graphics.setColor(statusColor(effects.motionBlur))
    love.graphics.print("[3] Motion Blur: " .. (effects.motionBlur and "ON" or "OFF"), 10, 115)

    love.graphics.setColor(statusColor(cameraSystem.enabled))
    love.graphics.print("[5] Cameras: " .. (cameraSystem.enabled and "ON" or "OFF"), 10, 135)

    -- View mode
    love.graphics.setColor(0.6, 0.8, 1.0)
    love.graphics.print("[V] View: " .. viewMode, 10, 160)

    -- Projection mode (only show in ortho view)
    if viewMode == "ortho" then
        love.graphics.setColor(0.5, 0.7, 0.9)
        love.graphics.print("[P] Projection: " .. projectionMode, 10, 180)
    end

    -- BPM / Music display (right side)
    local rightX = love.graphics.getWidth() - 200

    love.graphics.setColor(0.7, 0.7, 0.7)
    love.graphics.print("Music Sync:", rightX, 10)

    -- BPM with beat pulse effect and detection status
    local bpmPulse = 1 + music.beatPulse * 0.3
    love.graphics.setColor(1.0, 0.6 + music.beatPulse * 0.4, 0.3)
    local bpmText = string.format("BPM: %d", music.bpm)
    if beatDetection.analyzed then
        bpmText = bpmText .. string.format(" (detected, %.0f%%)", beatDetection.confidence * 100)
    end
    love.graphics.print(bpmText, rightX, 30)

    -- Beat indicator
    love.graphics.setColor(0.5, 0.5, 0.5)
    love.graphics.print("Beat:", rightX, 50)

    -- Draw 4 beat indicators
    for i = 1, music.beatsPerMeasure do
        local beatX = rightX + 50 + (i - 1) * 25
        local beatY = 55
        local currentBeat = math.floor(music.measurePhase * music.beatsPerMeasure) + 1

        if i == currentBeat then
            -- Active beat - pulsing
            local pulse = 1 - music.beatPhase
            love.graphics.setColor(1.0, 0.8, 0.3, 0.8 + pulse * 0.2)
            love.graphics.circle("fill", beatX, beatY, 8 + pulse * 3)
        else
            -- Inactive beat
            love.graphics.setColor(0.3, 0.3, 0.3)
            love.graphics.circle("fill", beatX, beatY, 6)
        end
    end

    -- Sync status
    love.graphics.setColor(statusColor(music.syncEnabled))
    love.graphics.print("[4] Sync: " .. (music.syncEnabled and "ON" or "OFF"), rightX, 75)

    -- Controls hint
    love.graphics.setColor(0.5, 0.5, 0.5)
    love.graphics.print("[T] Tap Tempo", rightX, 95)
    love.graphics.print("[,/.] BPM -/+5", rightX, 115)

    -- Music playback status
    if music.source then
        local musicColor = music.playing and {0.4, 1.0, 0.5} or {0.6, 0.4, 0.4}
        love.graphics.setColor(musicColor[1], musicColor[2], musicColor[3])
        love.graphics.print("[M] Music: " .. (music.playing and "ON" or "OFF"), rightX, 155)
    end

    -- Tap count indicator
    if #music.tapTimes > 0 then
        love.graphics.setColor(0.6, 0.8, 1.0)
        love.graphics.print("Taps: " .. #music.tapTimes .. "/" .. music.maxTaps, rightX, 135)
    end

    -- Camera system display
    if cameraSystem.enabled and viewMode == "demo" then
        local shot = cameraSystem.shots[cameraSystem.currentShot]
        love.graphics.setColor(0.8, 0.7, 1.0)
        love.graphics.print("Camera: " .. shot.name, rightX, 175)
        love.graphics.setColor(0.5, 0.5, 0.6)
        local beatsLeft = cameraSystem.beatsPerShot - cameraSystem.beatCount
        love.graphics.print("Next in: " .. beatsLeft .. " beats", rightX, 195)
    end

    -- Stats (bottom left) - only show in demo mode
    if viewMode == "demo" then
        love.graphics.setColor(0.5, 0.5, 0.5)
        love.graphics.print("Particles: " .. #particles.list, 10, 200)
    end

    -- CRT status
    love.graphics.setColor(crtEnabled and 0.4 or 0.6, crtEnabled and 1.0 or 0.4, crtEnabled and 0.5 or 0.4)
    love.graphics.print("[C] CRT: " .. (crtEnabled and "ON" or "OFF"), 10, 220)

    -- "Press SPACE to start" message
    if waitingToStart then
        local w, h = love.graphics.getWidth(), love.graphics.getHeight()
        local text = "Press SPACE to start"
        local font = love.graphics.getFont()
        local textW = font:getWidth(text)
        local pulse = 0.7 + math.sin(love.timer.getTime() * 3) * 0.3
        love.graphics.setColor(1, 1, 1, pulse)
        love.graphics.print(text, (w - textW) / 2, h / 2 + 100)
    end

    -- Apply CRT effect if enabled
    if crtEnabled and crtCanvas and crtShader then
        love.graphics.setCanvas()
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.setShader(crtShader)
        crtShader:send("time", love.timer.getTime())
        crtShader:send("resolution", {love.graphics.getWidth(), love.graphics.getHeight()})
        love.graphics.draw(crtCanvas, 0, 0)
        love.graphics.setShader()
    end
end

function love.keypressed(key)
    if key == "escape" then
        love.event.quit()
    elseif key == "left" then
        cube.rotationSpeed = cube.rotationSpeed - 0.3
        figure.rotationSpeed = figure.rotationSpeed - 0.15
    elseif key == "right" then
        cube.rotationSpeed = cube.rotationSpeed + 0.3
        figure.rotationSpeed = figure.rotationSpeed + 0.15
    elseif key == "up" or key == "=" or key == "+" then
        camera.position.z = math.max(100, camera.position.z - 50)
    elseif key == "down" or key == "-" then
        camera.position.z = camera.position.z + 50
    elseif key == "space" then
        if waitingToStart then
            -- Start the show
            waitingToStart = false
            if music.source then
                music.source:seek(music.loopStart)
                music.source:play()
                music.playing = true
            end
            -- Reset choreography
            choreography.currentIndex = 1
            choreography.beatsInCurrentSection = 0
            figure.currentAnim = choreography.sequence[1].anim
            figure.animTime = 0
        else
            cube.rotationSpeed = 0
            figure.rotationSpeed = 0
        end
    elseif key == "tab" then
        -- Cycle through animations
        currentAnimIndex = currentAnimIndex % #animationOrder + 1
        figure.currentAnim = animationOrder[currentAnimIndex]
        figure.animTime = 0  -- Reset animation time for clean transition
    -- Effect toggles
    elseif key == "1" then
        effects.particles = not effects.particles
    elseif key == "2" then
        effects.trails = not effects.trails
    elseif key == "3" then
        effects.motionBlur = not effects.motionBlur
    -- Music / BPM controls
    elseif key == "4" then
        music.syncEnabled = not music.syncEnabled
    elseif key == "t" then
        tapTempo()
    elseif key == "," or key == "[" then
        music.bpm = math.max(30, music.bpm - 5)
    elseif key == "." or key == "]" then
        music.bpm = math.min(300, music.bpm + 5)
    elseif key == "r" then
        -- Reset beat to downbeat
        music.beatTime = 0
        music.beatPulse = 1.0
    elseif key == "p" then
        -- Toggle projection mode (only in ortho view mode)
        if viewMode == "ortho" then
            if projectionMode == "ortho" then
                projectionMode = "perspective"
            else
                projectionMode = "ortho"
            end
        end
    elseif key == "v" then
        -- Toggle view mode
        if viewMode == "ortho" then
            viewMode = "demo"
            projectionMode = "perspective"  -- Demo uses perspective
        else
            viewMode = "ortho"
            projectionMode = "ortho"  -- Ortho view uses ortho projection
            figure.angle = 0  -- Reset rotation
        end
    elseif key == "m" then
        -- Toggle music playback
        if music.source then
            if music.playing then
                music.source:pause()
                music.playing = false
            else
                music.source:seek(music.loopStart)
                music.source:play()
                music.playing = true
            end
        end
    elseif key == "c" then
        -- Toggle CRT effect
        crtEnabled = not crtEnabled
    elseif key == "5" then
        -- Toggle camera system
        cameraSystem.enabled = not cameraSystem.enabled
        if cameraSystem.enabled then
            cameraSystem.beatCount = 0
            cameraSystem.shotTime = 0
        end
    elseif key == "n" then
        -- Force next camera shot
        if cameraSystem.enabled then
            switchCameraShot()
        end
    end
end
