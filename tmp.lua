-- -- local outputName = "Audioengine A2+"
-- -- local inputName  = "RØDE VideoMic NTG"  -- check exact name in Sound settings

-- -- local function pickDevices()
-- --   local out = hs.audiodevice.findOutputByName(outputName)
-- --   if out then out:setDefaultOutputDevice() end

-- --   local inp = hs.audiodevice.findInputByName(inputName)
-- --   if inp then inp:setDefaultInputDevice() end
-- -- end

-- -- -- run on wake
-- -- hs.caffeinate.watcher.new(function(event)
-- --   if event == hs.caffeinate.watcher.systemDidWake
-- --      or event == hs.caffeinate.watcher.screensDidWake then
-- --     hs.timer.doAfter(1.0, pickDevices)
-- --   end
-- -- end):start()

-- -- -- run when USB devices change (dock reconnect)
-- -- hs.usb.watcher.new(function(_)
-- --   hs.timer.doAfter(0.8, pickDevices)
-- -- end):start()

-- -- -- also run once at launch
-- -- hs.timer.doAfter(1.0, pickDevices)
