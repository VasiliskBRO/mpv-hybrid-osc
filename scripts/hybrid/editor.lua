-- Skin editor for the hybrid OSC: move and resize the elements of the bottom bar with the mouse.
-- Opened with "script-binding hybrid/editor" (Ctrl+E) or from the main menu.
-- Works on the skin table that layout=skin draws, so every change is visible at once.

local M = {}
local api                  -- functions from main.lua, see M.init()

local overlay = mp.create_osd_overlay("ass-events")
overlay.z = 2000
local ed = nil             -- editing state while the editor is open

local NAMES = {
    title = "Название", chapter_title = "Глава", seekbar = "Полоса перемотки",
    menu = "Кнопка меню", sub_track = "Субтитры", audio_track = "Аудиодорожки",
    time_codes = "Время", playlist_prev = "Предыдущее видео", playlist_next = "Следующее видео",
    jump_backward = "Назад", jump_forward = "Вперёд", play_pause = "Пауза",
    chapter_prev = "Предыдущая глава", chapter_next = "Следующая глава",
    speed_ruler = "Линейка скорости", speed = "Кнопка скорости", shuffle = "Перемешать",
    file_loop = "Повтор", playlist = "Плейлист", pip = "Картинка в картинке",
    fullscreen = "Полный экран", info = "Статистика", ontop = "Поверх окон",
    screenshot = "Скриншот", cache_info = "Кэш", download = "Скачать",
}
M.NAMES = NAMES

local T = {
    save = "Сохранить", undo = "Шаг назад", reset = "Как по умолчанию", exit = "Выйти",
    hint = "Тащи элемент мышкой, за уголок — размер · стрелки — точно · Delete — убрать · Tab — следующий",
    height = "высота фона",
    saved = "Скин сохранён",
    save_failed = "Не удалось сохранить: %s",
    unsaved = "Есть несохранённые изменения: «Сохранить» или ещё раз «Выйти» — выйти без сохранения",
    removed = "Убрано: %s (вернуть — «Шаг назад»)",
    reset_done = "Вернул стандартную раскладку (не сохранено)",
    hidden = "не всегда виден",
}

local HANDLE = 8       -- corner handle size
local MIN_SIZE = 6

-- helpers -------------------------------------------------------------------------------

local function bgr(color)
    color = color:gsub("^#", "")
    return color:sub(5, 6) .. color:sub(3, 4) .. color:sub(1, 2)
end

local function esc(text)
    local ok, escaped = pcall(mp.command_native, {"escape-ass", tostring(text)})
    return ok and escaped or tostring(text)
end

local function round(v) return math.floor(v * 2 + 0.5) / 2 end

local function mouse()
    local x, y = mp.get_mouse_pos()
    local sx, sy = api.scale()
    return x * sx, y * sy
end

local function inside(x, y, x1, y1, x2, y2)
    return x >= x1 and x <= x2 and y >= y1 and y <= y2
end

local function push_undo()
    ed.undo[#ed.undo + 1] = api.copy(ed.skin)
    if #ed.undo > 100 then table.remove(ed.undo, 1) end
    ed.dirty = true
    ed.confirm_exit = false
end

local function toast(text, seconds)
    ed.toast = text
    if ed.toast_timer then ed.toast_timer:kill() end
    ed.toast_timer = mp.add_timeout(seconds or 2.5, function ()
        if ed then ed.toast = nil M.render() end
    end)
end

local function relayout()
    api.set_skin(ed.skin)
    api.relayout()
end

-- current boxes of all items (window coordinates, virtual px)
local function entries()
    return api.resolve(ed.skin)
end

-- drawing -------------------------------------------------------------------------------

local function rect_path(x1, y1, x2, y2)
    return string.format("m %.1f %.1f l %.1f %.1f l %.1f %.1f l %.1f %.1f", x1, y1, x2, y1, x2, y2, x1, y2)
end

local function frame(ass, x1, y1, x2, y2, color, alpha, width)
    ass[#ass + 1] = string.format("{\\an7\\pos(0,0)\\bord%.1f\\shad0\\blur0\\1a&HFF&\\3c&H%s&\\3a&H%02X&\\p1}%s{\\p0}",
        width or 1, bgr(color), alpha or 0, rect_path(x1, y1, x2, y2))
end

local function fill(ass, x1, y1, x2, y2, color, alpha)
    ass[#ass + 1] = string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\blur0\\1c&H%s&\\1a&H%02X&\\p1}%s{\\p0}",
        bgr(color), alpha or 0, rect_path(x1, y1, x2, y2))
end

local function text(ass, x, y, an, str, size, color)
    ass[#ass + 1] = string.format("{\\an%d\\pos(%.1f,%.1f)\\fn%s\\fs%d\\bord2\\shad0\\blur0\\3c&H000000&\\1c&H%s&}%s",
        an, x, y, api.font(), size or 14, bgr(color or "#FFFFFF"), esc(str))
end

-- handles of the selected box: {name, x1, y1, x2, y2}
local function handles(e)
    local h = HANDLE
    return {
        {"tl", e.x1 - h / 2, e.y1 - h / 2, e.x1 + h / 2, e.y1 + h / 2},
        {"tr", e.x2 - h / 2, e.y1 - h / 2, e.x2 + h / 2, e.y1 + h / 2},
        {"bl", e.x1 - h / 2, e.y2 - h / 2, e.x1 + h / 2, e.y2 + h / 2},
        {"br", e.x2 - h / 2, e.y2 - h / 2, e.x2 + h / 2, e.y2 + h / 2},
    }
end

local function height_handle(W, H)
    local y = H - ed.skin.height
    return W - 140, y - 9, W - 20, y + 9, y
end

function M.render()
    if not ed then return end
    local W, H = api.dims()
    overlay.res_x, overlay.res_y = W, H
    local accent = api.accent()
    local ass = {}
    local list = entries()
    ed.list = list

    -- bar background height
    local hx1, hy1, hx2, hy2, bar_y = height_handle(W, H)
    fill(ass, 0, bar_y - 0.5, W, bar_y + 0.5, "#FFFFFF", 0x90)
    fill(ass, hx1, hy1, hx2, hy2, ed.hover == "height" and accent or "#202020", 0x30)
    text(ass, (hx1 + hx2) / 2, (hy1 + hy2) / 2, 5, "↕ " .. T.height, 12)

    -- item frames
    for i, e in ipairs(list) do
        if i ~= ed.selected then
            local color, alpha = "#FFFFFF", ed.hover == i and 0x00 or 0x70
            if not e.exists or not e.shown then color, alpha = "#9A9A9A", 0x80 end
            frame(ass, e.x1, e.y1, e.x2, e.y2, color, alpha, ed.hover == i and 1.5 or 1)
        end
    end

    -- selected item: accent frame, corner handles, name and numbers
    local sel = ed.selected and list[ed.selected]
    if sel then
        frame(ass, sel.x1, sel.y1, sel.x2, sel.y2, accent, 0, 2)
        for _, h in ipairs(handles(sel)) do
            fill(ass, h[2], h[3], h[4], h[5], accent, 0)
        end
        local item = sel.item
        local label = (NAMES[item.id] or item.id) .. string.format("  %d×%d", sel.x2 - sel.x1, sel.y2 - sel.y1)
        if not sel.shown then label = label .. " · " .. T.hidden end
        local ly = sel.y1 - 6
        if ly < 70 then ly = sel.y2 + 22 end
        text(ass, math.max(10, math.min(sel.x1, W - 300)), ly, 1, label, 14, accent)
    end

    -- toolbar
    local buttons = {
        {"save", T.save, ed.dirty}, {"undo", T.undo, #ed.undo > 0},
        {"reset", T.reset, true}, {"exit", T.exit, true},
    }
    local bw, bh, gap = 150, 30, 8
    local total = #buttons * bw + (#buttons - 1) * gap
    local x = (W - total) / 2
    ed.buttons = {}
    fill(ass, x - 10, 6, x + total + 10, 6 + bh + 34, "#000000", 0x50)
    for _, b in ipairs(buttons) do
        local x1, y1, x2, y2 = x, 12, x + bw, 12 + bh
        local hovered = ed.hover == b[1]
        local color = (b[1] == "save" and b[3]) and accent or "#303030"
        fill(ass, x1, y1, x2, y2, hovered and "#505050" or color, b[3] and 0x10 or 0x80)
        text(ass, (x1 + x2) / 2, (y1 + y2) / 2, 5, b[2], 14, b[3] and "#FFFFFF" or "#9A9A9A")
        ed.buttons[#ed.buttons + 1] = {id = b[1], x1 = x1, y1 = y1, x2 = x2, y2 = y2, enabled = b[3]}
        x = x2 + gap
    end
    text(ass, W / 2, 12 + bh + 15, 5, ed.toast or T.hint, 12, ed.toast and accent or "#DDDDDD")

    overlay.data = table.concat(ass, "\n")
    overlay:update()
end

-- hit testing ---------------------------------------------------------------------------

local function hit(x, y)
    for _, b in ipairs(ed.buttons or {}) do
        if inside(x, y, b.x1, b.y1, b.x2, b.y2) then return "button", b end
    end
    local list = ed.list or entries()
    local sel = ed.selected and list[ed.selected]
    if sel then
        for _, h in ipairs(handles(sel)) do
            if inside(x, y, h[2] - 2, h[3] - 2, h[4] + 2, h[5] + 2) then return "handle", h[1] end
        end
    end
    local W, H = api.dims()
    local hx1, hy1, hx2, hy2 = height_handle(W, H)
    if inside(x, y, hx1, hy1, hx2, hy2) then return "height" end
    -- the smallest box under the mouse wins (buttons over the long title)
    local best, best_area
    for i, e in ipairs(list) do
        if inside(x, y, e.x1 - 2, e.y1 - 2, e.x2 + 2, e.y2 + 2) then
            local area = (e.x2 - e.x1) * (e.y2 - e.y1)
            if not best or area < best_area then best, best_area = i, area end
        end
    end
    if best then return "item", best end
    return nil
end

-- editing actions -----------------------------------------------------------------------

-- after a move: count x from the third of the window the item is in, so it keeps its place
-- when the window gets wider or narrower
local function reanchor(index)
    local item = ed.skin.items[index]
    if item.anchor == "stretch" then return end
    local e = entries()[index]
    local W = api.dims()
    local cx = (e.x1 + e.x2) / 2
    local anchor = cx < W / 3 and "left" or (cx > W * 2 / 3 and "right" or "center")
    local ax = anchor == "center" and W / 2 or (anchor == "right" and W or 0)
    item.anchor = anchor
    item.x = round(e.x1 - ax)
end

local function apply_drag(x, y)
    local d = ed.drag
    local dx, dy = x - d.mx, y - d.my
    if d.mode == "height" then
        ed.skin.height = math.max(0, round(d.start.height - dy))
        relayout()
        return
    end
    local item = ed.skin.items[d.index]
    local s = d.start
    if d.mode == "move" then
        item.x = round(s.x + dx)
        if item.anchor == "stretch" then item.r = round(s.r - dx) end
        item.bottom = round(s.bottom - dy)
    else
        local corner = d.mode
        if corner:find("r") then
            if item.anchor == "stretch" then item.r = round(s.r - dx)
            else item.w = math.max(MIN_SIZE, round(s.w + dx)) end
        else
            local ddx = dx
            if item.anchor ~= "stretch" then ddx = math.min(dx, s.w - MIN_SIZE) end
            item.x = round(s.x + ddx)
            if item.anchor ~= "stretch" then item.w = round(s.w - ddx) end
        end
        if corner:find("t") then
            item.h = math.max(MIN_SIZE, round(s.h - dy))
        else
            local ddy = math.max(dy, -(s.h - MIN_SIZE))
            item.bottom = round(s.bottom - ddy)
            item.h = round(s.h + ddy)
        end
    end
    relayout()
end

local function nudge(dx, dy)
    local item = ed.selected and ed.skin.items[ed.selected]
    if not item then return end
    push_undo()
    item.x = item.x + dx
    if item.anchor == "stretch" then item.r = item.r - dx end
    item.bottom = item.bottom - dy
    relayout()
    M.render()
end

local function remove_selected()
    local item = ed.selected and ed.skin.items[ed.selected]
    if not item then return end
    push_undo()
    table.remove(ed.skin.items, ed.selected)
    ed.selected = nil
    toast(string.format(T.removed, NAMES[item.id] or item.id))
    relayout()
    M.render()
end

local function undo()
    if #ed.undo == 0 then return end
    ed.skin = table.remove(ed.undo)
    ed.dirty = true
    if ed.selected and not ed.skin.items[ed.selected] then ed.selected = nil end
    relayout()
    M.render()
end

local function save()
    local ok, err = api.save(ed.skin)
    if ok then
        ed.snapshot = api.copy(ed.skin)
        ed.dirty = false
        toast(T.saved)
    else
        toast(string.format(T.save_failed, tostring(err)), 5)
    end
    M.render()
end

local close

local function press_button(id)
    if id == "save" then
        if ed.dirty then save() end
    elseif id == "undo" then
        undo()
    elseif id == "reset" then
        push_undo()
        ed.skin = api.default_skin()
        ed.selected = nil
        relayout()
        toast(T.reset_done)
        M.render()
    elseif id == "exit" then
        if ed.dirty and not ed.confirm_exit then
            ed.confirm_exit = true
            toast(T.unsaved, 6)
            M.render()
        else
            close()
        end
    end
end

-- input ---------------------------------------------------------------------------------

local function on_mouse_move()
    local x, y = mouse()
    if ed.drag then
        apply_drag(x, y)
        M.render()
        return
    end
    local kind, value = hit(x, y)
    local hover = nil
    if kind == "button" then hover = value.id
    elseif kind == "item" then hover = value
    elseif kind == "height" then hover = "height" end
    if hover ~= ed.hover then
        ed.hover = hover
        M.render()
    end
end

local function on_left(info)
    local x, y = mouse()
    if info.event == "down" then
        local kind, value = hit(x, y)
        if kind == "button" then
            ed.pressed_button = value
            return
        end
        if kind == "handle" or kind == "item" or kind == "height" then
            if kind == "item" then ed.selected = value end
            local dirty_before, confirm_before = ed.dirty, ed.confirm_exit
            push_undo()
            local mode = kind == "handle" and value or (kind == "height" and "height" or "move")
            local start = kind == "height" and {height = ed.skin.height} or api.copy(ed.skin.items[ed.selected])
            ed.drag = {mode = mode, index = ed.selected, mx = x, my = y, start = start,
                dirty_before = dirty_before, confirm_before = confirm_before}
        else
            ed.selected = nil
        end
        M.render()
    elseif info.event == "up" then
        if ed.pressed_button then
            local b = ed.pressed_button
            ed.pressed_button = nil
            if inside(x, y, b.x1, b.y1, b.x2, b.y2) and b.enabled then press_button(b.id) end
            return
        end
        local d = ed.drag
        if d then
            ed.drag = nil
            if math.abs(x - d.mx) < 1 and math.abs(y - d.my) < 1 then
                -- just a click: drop the undo step pushed on press
                table.remove(ed.undo)
                ed.dirty, ed.confirm_exit = d.dirty_before, d.confirm_before
            elseif d.mode == "move" then
                reanchor(d.index)
                relayout()
            end
            M.render()
        end
    end
end

local bindings
local MOUSE_SECTION = "hybrid_editor_mouse"

local function bind()
    -- the mouse goes through a section whose mouse area is the whole window: such a section
    -- forbids window dragging, otherwise holding the button and moving would move the mpv
    -- window (and mpv would release the button in the middle of a drag)
    local function noop() end
    mp.set_key_bindings({
        {"mouse_move", on_mouse_move},
        {"mbtn_left", function () on_left({event = "up"}) end, function () on_left({event = "down"}) end},
        {"mbtn_left_dbl", noop}, {"mbtn_right", noop}, {"mbtn_right_dbl", noop}, {"mbtn_mid", noop},
        {"wheel_up", noop}, {"wheel_down", noop}, {"wheel_left", noop}, {"wheel_right", noop},
    }, MOUSE_SECTION, "force")
    mp.set_mouse_area(0, 0, 100000, 100000, MOUSE_SECTION)
    mp.enable_key_bindings(MOUSE_SECTION)

    local list = {
        {"left", function () nudge(-1, 0) end, {repeatable = true}},
        {"right", function () nudge(1, 0) end, {repeatable = true}},
        {"up", function () nudge(0, -1) end, {repeatable = true}},
        {"down", function () nudge(0, 1) end, {repeatable = true}},
        {"shift+left", function () nudge(-10, 0) end, {repeatable = true}},
        {"shift+right", function () nudge(10, 0) end, {repeatable = true}},
        {"shift+up", function () nudge(0, -10) end, {repeatable = true}},
        {"shift+down", function () nudge(0, 10) end, {repeatable = true}},
        {"tab", function ()
            local n = #ed.skin.items
            if n == 0 then return end
            ed.selected = ((ed.selected or 0) % n) + 1
            M.render()
        end},
        {"del", remove_selected},
        {"ctrl+z", undo},
        {"ctrl+s", function () if ed.dirty then save() end end},
        {"esc", function ()
            if ed.selected then ed.selected = nil M.render() else press_button("exit") end
        end},
        {"space", function () end}, {"q", function () end}, {"Q", function () end},
    }
    bindings = list
    for i, b in ipairs(list) do
        mp.add_forced_key_binding(b[1], "hybrid-editor-" .. i, b[2], b[3])
    end
end

local function unbind()
    mp.disable_key_bindings(MOUSE_SECTION)
    for i in ipairs(bindings or {}) do mp.remove_key_binding("hybrid-editor-" .. i) end
    bindings = nil
end

-- open / close --------------------------------------------------------------------------

function M.is_open() return ed ~= nil end

function M.open()
    if ed then return end
    local skin = api.get_skin()
    ed = {
        skin = skin, snapshot = api.copy(skin), undo = {}, dirty = false,
        was_paused = mp.get_property_native("pause"),
    }
    mp.set_property_native("pause", true)
    api.set_editing(true)
    bind()
    -- the bar is laid out on the next tick; draw once it is there
    mp.add_timeout(0.1, M.render)
end

close = function ()
    if not ed then return end
    if ed.dirty then api.set_skin(ed.snapshot) end -- leaving without saving
    if ed.toast_timer then ed.toast_timer:kill() end
    local was_paused = ed.was_paused
    ed = nil
    unbind()
    overlay.data = ""
    overlay:remove()
    api.set_editing(false)
    mp.set_property_native("pause", was_paused)
end
M.close = close

function M.toggle()
    if ed then press_button("exit") else M.open() end
end

function M.init(functions)
    api = functions
    mp.add_key_binding(nil, "editor", M.toggle)
    mp.observe_property("osd-dimensions", "native", function ()
        if ed then mp.add_timeout(0.05, M.render) end
    end)
end

return M
