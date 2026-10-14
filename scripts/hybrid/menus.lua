-- Menu contents for the hybrid OSC (in Russian). Rendering lives in menu.lua.

local utils = require "mp.utils"

local M = {}
local menu -- renderer, set in M.init()

local T = {
    menu = "Меню",
    open_file = "Открыть файл…",
    load_subs = "Загрузить субтитры…",
    playlist = "Плейлист",
    playlist_empty = "Плейлист пуст",
    chapters = "Главы",
    chapter = "Глава",
    subtitles = "Субтитры",
    audio = "Аудиодорожка",
    video = "Видеодорожка",
    off = "Выключить",
    off_hint = "выкл",
    speed = "Скорость",
    normal = "обычная",
    aspect = "Соотношение сторон",
    aspect_auto = "Как в видео",
    loop = "Повтор",
    loop_off = "Не повторять",
    loop_file = "Повторять файл",
    loop_playlist = "Повторять плейлист",
    loop_off_hint = "нет",
    loop_file_hint = "файл",
    loop_playlist_hint = "плейлист",
    audio_device = "Аудиоустройство",
    screenshot = "Скриншот",
    show_in_folder = "Показать в папке",
    stats = "Статистика",
    quit = "Выход",
    computer = "Этот компьютер",
    up = "наверх",
    external = "внешние",
    forced = "принудит.",
    default = "по умолчанию",
    track = "Дорожка",
}

local LANGS = {
    rus = "Русский", ru = "Русский", eng = "Английский", en = "Английский",
    ukr = "Украинский", uk = "Украинский", jpn = "Японский", ja = "Японский",
    ger = "Немецкий", deu = "Немецкий", de = "Немецкий", fre = "Французский", fra = "Французский",
    fr = "Французский", spa = "Испанский", es = "Испанский", ita = "Итальянский", it = "Итальянский",
    chi = "Китайский", zho = "Китайский", zh = "Китайский", kor = "Корейский", ko = "Корейский",
    por = "Португальский", pt = "Португальский", pol = "Польский", pl = "Польский",
    tur = "Турецкий", tr = "Турецкий", ara = "Арабский", ar = "Арабский",
}

local MEDIA_EXT = {}
for ext in ("mkv mp4 m4v webm avi mov wmv flv ts m2ts mts mpg mpeg vob ogv 3gp rmvb " ..
            "mp3 flac m4a aac ogg opus wav wma ape alac mka " ..
            "jpg jpeg png webp gif bmp avif jxl m3u m3u8 pls cue iso"):gmatch("%S+") do
    MEDIA_EXT[ext] = true
end
local SUB_EXT = {}
for ext in ("srt ass ssa vtt sub idx sup smi lrc ttml"):gmatch("%S+") do SUB_EXT[ext] = true end

-- helpers ---------------------------------------------------------------------------------

local function prop(name, default)
    local value = mp.get_property_native(name)
    if value == nil then return default end
    return value
end

local function format_time(seconds)
    seconds = math.floor(seconds or 0)
    local h, m, s = math.floor(seconds / 3600), math.floor(seconds % 3600 / 60), seconds % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
end

local function format_speed(speed)
    return string.format("%g×", math.floor(speed * 100 + 0.5) / 100)
end

local function lang_name(lang)
    if not lang or lang == "" or lang == "und" then return nil end
    return LANGS[lang:lower()] or lang:upper()
end

local function extension(name)
    return (name:match("%.([^%.\\/]+)$") or ""):lower()
end

local function is_url(path)
    return path and path:find("^%a[%w+.-]*://") ~= nil
end

local function natural_key(name)
    return name:lower():gsub("%d+", function (d) return string.rep("0", 12 - #d) .. d end)
end

local function sorted(list)
    table.sort(list, function (a, b) return natural_key(a) < natural_key(b) end)
    return list
end

local function absolute_path(path)
    if not path or is_url(path) then return nil end
    if not path:match("^%a:[\\/]") and not path:match("^[\\/]") then
        path = utils.join_path(prop("working-directory", ""), path)
    end
    return (path:gsub("/", "\\"))
end

local function parent_dir(path)
    path = path:gsub("[\\/]+$", "")
    if path:match("^%a:$") then return nil end -- drive root -> drive list
    local dir = path:match("^(.*)[\\/][^\\/]*$")
    if not dir or dir == "" then return nil end
    if dir:match("^%a:$") then dir = dir .. "\\" end
    return dir
end

local function join(dir, name)
    if dir:match("[\\/]$") then return dir .. name end
    return dir .. "\\" .. name
end

local function start_dir()
    local path = absolute_path(mp.get_property("path"))
    if path then
        local dir = parent_dir(path)
        if dir and utils.readdir(dir) then return dir end
    end
    local home = os.getenv("USERPROFILE")
    if home and utils.readdir(home) then return home end
    return nil
end

local function track_label(track)
    local hint = {}
    local lang = lang_name(track.lang)
    if lang and track.title then hint[#hint + 1] = lang end
    if track.codec then hint[#hint + 1] = track.codec end
    if track.type == "audio" and track["demux-channel-count"] then
        hint[#hint + 1] = track["demux-channel-count"] .. "ch"
    end
    if track.type == "video" and track["demux-w"] then
        hint[#hint + 1] = track["demux-w"] .. "×" .. track["demux-h"]
    end
    if track.external then hint[#hint + 1] = T.external end
    if track.forced then hint[#hint + 1] = T.forced end
    local title = track.title or lang or (T.track .. " " .. track.id)
    return title, table.concat(hint, ", ")
end

-- builders ---------------------------------------------------------------------------------

local browser

local function tracks(kind, title, property)
    return function ()
        local items = {}
        local any_selected = false
        local list = {}
        for _, track in ipairs(prop("track-list", {})) do
            if track.type == kind then
                list[#list + 1] = track
                any_selected = any_selected or track.selected
            end
        end
        if kind ~= "video" then
            items[#items + 1] = {
                title = T.off, icon = kind == "sub" and "subtitles_off" or "volume_off",
                active = not any_selected,
                action = function () mp.commandv("set", property, "no") end,
            }
        end
        for _, track in ipairs(list) do
            local label, hint = track_label(track)
            items[#items + 1] = {
                title = label, hint = hint, active = track.selected,
                action = function () mp.commandv("set", property, tostring(track.id)) end,
            }
        end
        if kind == "sub" then
            items[#items].separator = true
            items[#items + 1] = {title = T.load_subs, icon = "file_open", submenu = browser(start_dir(), "sub")}
        end
        return {title = title, items = items}
    end
end

local function playlist()
    local items = {}
    for i, entry in ipairs(prop("playlist", {})) do
        local name = entry.title
        if not name or name == "" then
            name = is_url(entry.filename) and entry.filename or (entry.filename:match("([^\\/]+)$") or entry.filename)
        end
        items[#items + 1] = {
            title = name, hint = tostring(i), active = entry.current or entry.playing,
            action = function () mp.commandv("playlist-play-index", tostring(i - 1)) end,
        }
    end
    if #items == 0 then
        items[1] = {title = T.playlist_empty, muted = true}
        items[2] = {title = T.open_file, icon = "folder_open", submenu = browser(start_dir(), "media")}
    end
    return {title = T.playlist, items = items}
end

local function chapters()
    local items = {}
    local current = prop("chapter", -1)
    for i, chapter in ipairs(prop("chapter-list", {})) do
        local name = chapter.title
        if not name or name == "" then name = T.chapter .. " " .. i end
        items[#items + 1] = {
            title = name, hint = format_time(chapter.time), active = (i - 1) == current,
            action = function () mp.set_property_native("chapter", i - 1) end,
        }
    end
    return {title = T.chapters, items = items}
end

local function speeds()
    local items = {}
    local current = prop("speed", 1)
    for _, value in ipairs({0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4}) do
        items[#items + 1] = {
            title = format_speed(value), hint = value == 1 and T.normal or nil,
            active = math.abs(current - value) < 0.001,
            action = function () mp.set_property_native("speed", value) end,
        }
    end
    return {title = T.speed, items = items}
end

local function audio_devices()
    local items = {}
    local current = prop("audio-device", "auto")
    for _, device in ipairs(prop("audio-device-list", {})) do
        items[#items + 1] = {
            title = device.description or device.name, hint = device.name == "auto" and "" or nil,
            active = device.name == current,
            action = function () mp.set_property("audio-device", device.name) end,
        }
    end
    return {title = T.audio_device, items = items}
end

local function aspects()
    -- values <= 0 mean "use the video's own aspect" (the default differs between mpv versions)
    local current = mp.get_property_number("video-aspect-override") or -1
    local default = mp.get_property("option-info/video-aspect-override/default-value") or "-1"
    local items = {}
    for _, a in ipairs({{T.aspect_auto, default, -1}, {"16:9", "16:9", 16 / 9}, {"4:3", "4:3", 4 / 3},
                        {"21:9", "21:9", 21 / 9}, {"2.35:1", "2.35:1", 2.35}, {"1:1", "1:1", 1}}) do
        local active = a[3] < 0 and current <= 0 or math.abs(current - a[3]) < 0.01
        items[#items + 1] = {
            title = a[1], active = active,
            action = function () mp.commandv("set", "video-aspect-override", a[2]) end,
        }
    end
    return {title = T.aspect, items = items}
end

local function loop_state()
    local file = prop("loop-file", false)
    local list = prop("loop-playlist", false)
    if file and file ~= "no" then return "file" end
    if list and list ~= "no" then return "playlist" end
    return "off"
end

local function loops()
    local current = loop_state()
    return {title = T.loop, items = {
        {title = T.loop_off, icon = "repeat", active = current == "off", action = function ()
            mp.set_property("loop-file", "no"); mp.set_property("loop-playlist", "no")
        end},
        {title = T.loop_file, icon = "repeat_one", active = current == "file", action = function ()
            mp.set_property("loop-file", "inf")
        end},
        {title = T.loop_playlist, icon = "repeat_on", active = current == "playlist", action = function ()
            mp.set_property("loop-file", "no"); mp.set_property("loop-playlist", "inf")
        end},
    }}
end

-- file browser: mode "media" opens files, "sub" adds subtitles
browser = function (dir, mode)
    return function ()
        local items = {}
        local filter = mode == "sub" and SUB_EXT or MEDIA_EXT
        local current = absolute_path(mp.get_property("path"))
        if not dir then
            for code = string.byte("A"), string.byte("Z") do
                local drive = string.char(code) .. ":\\"
                if utils.readdir(drive) then
                    items[#items + 1] = {title = drive, icon = "storage", action = function ()
                        menu.replace(browser(drive, mode)) return "stay"
                    end}
                end
            end
            return {title = T.computer, items = items}
        end

        local parent = parent_dir(dir)
        items[1] = {title = "..", icon = "arrow_upward", hint = T.up, action = function ()
            menu.replace(browser(parent, mode)) return "stay"
        end}
        for _, name in ipairs(sorted(utils.readdir(dir, "dirs") or {})) do
            if not name:match("^%.") and not name:match("^%$") and name ~= "System Volume Information" then
                items[#items + 1] = {title = name, icon = "folder", action = function ()
                    menu.replace(browser(join(dir, name), mode)) return "stay"
                end}
            end
        end
        local selected
        for _, name in ipairs(sorted(utils.readdir(dir, "files") or {})) do
            if filter[extension(name)] then
                local full = join(dir, name)
                local is_current = current and full:lower() == current:lower()
                items[#items + 1] = {
                    title = name, icon = mode == "sub" and "subtitles" or "movie", active = is_current,
                    action = function ()
                        if mode == "sub" then
                            mp.commandv("sub-add", full, "select")
                        else
                            mp.commandv("loadfile", full)
                        end
                    end,
                }
                if is_current then selected = #items end
            end
        end
        return {title = dir, items = items, selected = selected or (#items > 1 and 2 or 1), on_back = function ()
            menu.replace(browser(parent, mode))
            return true
        end}
    end
end

local function main_menu()
    local items = {}
    local function add(item) items[#items + 1] = item end
    local track_counts = {video = 0, audio = 0, sub = 0}
    local current = {}
    for _, track in ipairs(prop("track-list", {})) do
        track_counts[track.type] = (track_counts[track.type] or 0) + 1
        if track.selected then current[track.type] = track_label(track) end
    end
    local pl_count = prop("playlist-count", 0)
    local ch_count = prop("chapter-list/count", 0)
    local path = absolute_path(mp.get_property("path"))

    add({title = T.open_file, icon = "folder_open", hint = "Ctrl+O", submenu = browser(start_dir(), "media")})
    add({title = T.playlist, icon = "queue_music",
         hint = pl_count > 0 and (prop("playlist-pos-1", 0) .. "/" .. pl_count) or nil, submenu = playlist})
    if ch_count > 0 then
        add({title = T.chapters, icon = "bookmarks", hint = tostring(ch_count), submenu = chapters})
    end
    add({title = T.subtitles, icon = "subtitles", hint = current.sub or T.off_hint,
         submenu = tracks("sub", T.subtitles, "sid")})
    if track_counts.audio > 0 then
        add({title = T.audio, icon = "audiotrack", hint = current.audio, submenu = tracks("audio", T.audio, "aid")})
    end
    if track_counts.video > 1 then
        add({title = T.video, icon = "movie", hint = current.video, submenu = tracks("video", T.video, "vid")})
    end
    add({title = T.speed, icon = "speed", hint = format_speed(prop("speed", 1)), submenu = speeds})
    add({title = T.aspect, icon = "aspect_ratio", submenu = aspects})
    local loop_hints = {off = T.loop_off_hint, file = T.loop_file_hint, playlist = T.loop_playlist_hint}
    add({title = T.loop, icon = "repeat", hint = loop_hints[loop_state()], submenu = loops})
    add({title = T.audio_device, icon = "speaker", submenu = audio_devices, separator = true})
    add({title = T.screenshot, icon = "photo_camera", hint = "S", action = function ()
        mp.add_timeout(0.15, function () mp.commandv("osd-msg", "screenshot") end)
    end})
    if path then
        add({title = T.show_in_folder, icon = "folder", action = function ()
            mp.commandv("run", "explorer", "/select," .. path)
        end})
    end
    add({title = T.stats, icon = "query_stats", hint = "I", action = function ()
        mp.command("script-binding stats/display-stats-toggle")
    end})
    add({title = T.quit, icon = "logout", hint = "Q", action = function () mp.command("quit") end})
    return {title = T.menu, items = items}
end

-- public ----------------------------------------------------------------------------------

function M.init(renderer)
    menu = renderer
    local function binding(name, id, builder)
        mp.add_key_binding(nil, name, function () menu.open(id, builder) end)
    end
    binding("menu", "main", main_menu)
    binding("subtitles", "subtitles", tracks("sub", T.subtitles, "sid"))
    binding("audio", "audio", tracks("audio", T.audio, "aid"))
    binding("video", "video", tracks("video", T.video, "vid"))
    binding("playlist", "playlist", playlist)
    binding("chapters", "chapters", chapters)
    binding("speed", "speed", speeds)
    binding("audio-device", "audio-device", audio_devices)
    binding("aspect", "aspect", aspects)
    binding("loop", "loop", loops)
    mp.add_key_binding(nil, "open-file", function () menu.open("open-file", browser(start_dir(), "media")) end)
    mp.add_key_binding(nil, "load-subtitles", function () menu.open("load-subtitles", browser(start_dir(), "sub")) end)
end

return M
