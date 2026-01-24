function love.conf(t)
    t.title = "FakinIt - Fake 3D"
    t.version = "11.4"
    t.window.width = 800
    t.window.height = 600
    t.window.resizable = true
    t.window.vsync = 1

    -- Disable unused modules for cleaner startup
    t.modules.joystick = false
    t.modules.physics = false
    t.modules.touch = false
end
