-- forget-finished.lua — не запоминать позицию у досмотренных видео
-- Если при выходе видео досмотрено (конец, >= END_PERCENT % или осталось <= END_SECONDS),
-- метка «продолжить с…» стирается. Если старая метка стоит у самого конца — открываем с начала.

local END_PERCENT = 95
local END_SECONDS = 30

local function is_near_end(pos, dur)
    if not pos or not dur or dur <= 0 then return false end
    if pos / dur * 100 >= END_PERCENT then return true end
    -- для коротких роликов правило «30 секунд до конца» не применяем
    return dur > END_SECONDS * 4 and dur - pos <= END_SECONDS
end

-- выход/переключение файла: quit уже записал позицию, стираем её, если видео досмотрено
mp.add_hook("on_unload", 50, function ()
    local finished = mp.get_property_bool("eof-reached")
        or is_near_end(mp.get_property_number("time-pos"), mp.get_property_number("duration"))
    if finished then
        mp.command("delete-watch-later-config")
    end
end)

-- открытие: старая метка у самого конца -> начинаем с начала
mp.add_hook("on_preloaded", 50, function ()
    if mp.get_property_native("option-info/start/set-from-commandline") then return end
    local start = tonumber(mp.get_property("file-local-options/start", ""))
    if start and is_near_end(start, mp.get_property_number("duration")) then
        mp.set_property("file-local-options/start", "none")
        mp.command("delete-watch-later-config")
    end
end)
