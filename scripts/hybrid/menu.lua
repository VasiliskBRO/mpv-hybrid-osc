-- Menu renderer for the hybrid OSC.
-- Behaves like uosc menus (submenus, type-to-search, keyboard and mouse navigation),
-- drawn in the ModernZ style (dark translucent panel, accent highlight).
--
-- A menu level is built by a function returning:
--   { title = "...", items = { item, ... }, selected = index (optional) }
-- Item fields:
--   title, hint, icon (Material Icons name), active (current value), muted, bold,
--   separator (line below), submenu (builder function), action (function(item);
--   return "keep" to stay open and refresh, "stay" to stay without refresh)
-- A level may also return on_back = function() -> true when it handled "back" itself.

local assdraw = require "mp.assdraw"

local M = {}

local cfg = {
    font = "Segoe UI",
    icon_font = "Material Icons Round",
    accent = "#FF8232",
    bg = "#000000",
    fg = "#FFFFFF",
    muted = "#9A9A9A",
    outline = "#404040",
    width = 400,
    item_height = 32,
    font_size = 15,
    on_open = nil,
    on_close = nil,
    text = {search = "Поиск", empty = "Ничего не найдено", back = "Назад"},
}

local overlay = mp.create_osd_overlay("ass-events")
local stack = {}            -- open levels, stack[#stack] is the current one
local is_open = false
local root_id = nil
local mouse = {x = -1, y = -1, moved = false}
local pressed = {}          -- mouse buttons pressed while the menu was open
local geo = nil             -- geometry of the last render (for hit testing)
local res = {w = 1280, h = 720, sx = 1, sy = 1}

-- helpers ---------------------------------------------------------------------------

local function bgr(color)
    return color:sub(6, 7) .. color:sub(4, 5) .. color:sub(2, 3)
end

local function esc(text)
    text = tostring(text or "")
    local ok, escaped = pcall(mp.command_native, {"escape-ass", text})
    if ok and escaped then return escaped end
    return (text:gsub("\\", "\\\226\129\160"):gsub("{", "\\{"))
end

-- lowercase including Cyrillic (UTF-8)
local function lower(text)
    text = text:lower()
    text = text:gsub("\208([\144-\159])", function (c) return "\208" .. string.char(c:byte() + 32) end)
    text = text:gsub("\208([\160-\175])", function (c) return "\209" .. string.char(c:byte() - 32) end)
    text = text:gsub("\208\129", "\209\145") -- Ё -> ё
    return text
end

local function utf8_pop(text)
    local i = #text
    while i > 0 do
        local b = text:byte(i)
        if b < 0x80 or b >= 0xC0 then break end
        i = i - 1
    end
    return text:sub(1, math.max(0, i - 1))
end

local function clamp(lo, v, hi) return math.max(lo, math.min(hi, v)) end

local function current() return stack[#stack] end

-- levels ------------------------------------------------------------------------------

local function apply_filter(level)
    level.filtered = {}
    local query = lower(level.search)
    for i, item in ipairs(level.items) do
        if query == "" then
            level.filtered[#level.filtered + 1] = i
        else
            local hay = lower((item.title or "") .. " " .. (item.hint or ""))
            if hay:find(query, 1, true) then level.filtered[#level.filtered + 1] = i end
        end
    end
    level.selected = clamp(1, level.selected or 1, math.max(1, #level.filtered))
end

local function build(level, keep_position)
    local spec = level.builder() or {}
    level.title = spec.title or ""
    level.items = spec.items or {}
    level.on_back = spec.on_back
    if not keep_position then
        local selected = spec.selected
        if not selected then
            for i, item in ipairs(level.items) do
                if item.active then selected = i break end
            end
        end
        level.selected = selected or 1
        level.scroll = nil -- center on the selection at first render
    end
    apply_filter(level)
end

local function new_level(builder)
    local level = {builder = builder, search = "", selected = 1, scroll = nil, items = {}, filtered = {}}
    build(level)
    return level
end

-- rendering ---------------------------------------------------------------------------

local function update_resolution()
    local dims = mp.get_property_native("osd-dimensions") or {}
    local ow, oh = dims.w or 0, dims.h or 0
    if ow <= 0 or oh <= 0 then return false end
    -- 720 virtual lines on big windows, no shrinking below ~420 lines on small ones
    res.h = clamp(420, oh, 720)
    res.w = res.h * ow / oh
    res.sx, res.sy = res.w / ow, res.h / oh
    return true
end

local function layer(ass, color, alpha, extra)
    ass:new_event()
    ass:append(string.format("{\\rDefault\\an7\\pos(0,0)\\blur0\\bord0\\shad0\\1c&H%s&\\1a&H%02X&%s}",
        bgr(color), alpha or 0, extra or ""))
end

local function text(ass, x, y, an, str, size, color, extra, font)
    ass:new_event()
    ass:append(string.format("{\\rDefault\\an%d\\pos(%f,%f)\\fn%s\\fs%d\\bord0\\shad0\\blur0\\1c&H%s&%s}",
        an, x, y, font or cfg.font, size, bgr(color), extra or ""))
    ass:append(str)
end

local function icon(ass, x, y, name, size, color, extra)
    text(ass, x, y, 5, name, size, color, extra, cfg.icon_font)
end

local function render()
    if not is_open then return end
    local level = current()
    if not level or not update_resolution() then return end

    local item_h = cfg.item_height
    local pad = 6
    local title_h = 40
    local search_h = level.search ~= "" and 32 or 0
    local width = math.min(cfg.width, res.w - 40)
    local count = #level.filtered
    local max_rows = math.max(1, math.floor((res.h * 0.82 - title_h - search_h - pad * 2) / item_h))
    local rows = math.max(1, math.min(count, max_rows))
    local panel_h = title_h + search_h + pad * 2 + rows * item_h
    local x1 = math.floor((res.w - width) / 2)
    local y1 = math.floor((res.h - panel_h) / 2)
    local x2, y2 = x1 + width, y1 + panel_h
    local items_y = y1 + title_h + search_h + pad

    -- keep the selection inside the visible window
    local max_scroll = math.max(0, count - rows)
    if level.scroll == nil then
        level.scroll = clamp(0, level.selected - math.ceil(rows / 2), max_scroll)
    end
    level.scroll = clamp(0, level.scroll, max_scroll)

    geo = {x1 = x1, y1 = y1, x2 = x2, y2 = y2, items_y = items_y, item_h = item_h, rows = rows, title_h = title_h}

    local ass = assdraw.ass_new()

    -- curtain
    layer(ass, "#000000", 0x90)
    ass:draw_start()
    ass:rect_cw(0, 0, res.w, res.h)
    ass:draw_stop()

    -- panel
    layer(ass, cfg.bg, 0x1A, string.format("\\bord1\\3c&H%s&", bgr(cfg.outline)))
    ass:draw_start()
    ass:round_rect_cw(x1, y1, x2, y2, 10)
    ass:draw_stop()

    -- title row
    local title_x1 = x1 + 16
    if #stack > 1 then
        icon(ass, x1 + 22, y1 + title_h / 2, "arrow_back", 20,
            (mouse.x >= x1 and mouse.x <= x1 + 44 and mouse.y >= y1 and mouse.y <= y1 + title_h) and cfg.accent or cfg.muted)
        title_x1 = x1 + 44
    end
    text(ass, (title_x1 + x2 - 16) / 2, y1 + title_h / 2, 5, esc(level.title), cfg.font_size, cfg.muted,
        string.format("\\b1\\clip(%f,%f,%f,%f)", title_x1, y1, x2 - 16, y1 + title_h))
    layer(ass, "#FFFFFF", 0xE0)
    ass:draw_start()
    ass:rect_cw(x1 + 10, y1 + title_h - 1, x2 - 10, y1 + title_h)
    ass:draw_stop()

    -- search row
    if search_h > 0 then
        local sy = y1 + title_h + search_h / 2 + 2
        icon(ass, x1 + 24, sy, "search", 18, cfg.accent)
        text(ass, x1 + 42, sy, 4, esc(level.search) .. "{\\1c&H" .. bgr(cfg.accent) .. "&}▏", cfg.font_size, cfg.fg,
            string.format("\\clip(%f,%f,%f,%f)", x1 + 42, y1 + title_h, x2 - 12, y1 + title_h + search_h))
    end

    -- items
    if count == 0 then
        text(ass, (x1 + x2) / 2, items_y + item_h / 2, 5, esc(cfg.text.empty), cfg.font_size, cfg.muted)
    end
    for row = 1, rows do
        local fi = level.scroll + row
        local index = level.filtered[fi]
        if not index then break end
        local item = level.items[index]
        local iy = items_y + (row - 1) * item_h
        local cy = iy + item_h / 2
        local selected = fi == level.selected

        if selected then
            layer(ass, cfg.accent, 0xB0)
            ass:draw_start()
            ass:round_rect_cw(x1 + 5, iy + 1, x2 - 5, iy + item_h - 1, 6)
            ass:draw_stop()
        end
        if item.active then
            layer(ass, cfg.accent, 0)
            ass:draw_start()
            ass:round_rect_cw(x1 + 7, iy + 8, x1 + 10, iy + item_h - 8, 1.5)
            ass:draw_stop()
        end

        local color = item.active and cfg.accent or (item.muted and cfg.muted or cfg.fg)
        if selected and item.active then color = cfg.fg end
        local tx = x1 + 18
        if item.icon then
            icon(ass, x1 + 28, cy, item.icon, 19, color)
            tx = x1 + 46
        end

        local right = x2 - 14
        if item.submenu then
            icon(ass, x2 - 20, cy, "chevron_right", 20, cfg.muted)
            right = x2 - 34
        end
        local hint_w = 0
        if item.hint and item.hint ~= "" then
            hint_w = math.min(width * 0.45, #item.hint * cfg.font_size * 0.42 + 8)
            text(ass, right, cy, 6, esc(item.hint), cfg.font_size - 2, selected and cfg.fg or cfg.muted,
                string.format("\\clip(%f,%f,%f,%f)", right - hint_w, iy, right, iy + item_h))
        end
        text(ass, tx, cy, 4, esc(item.title), cfg.font_size, color,
            string.format("%s\\clip(%f,%f,%f,%f)", (item.bold or item.active) and "\\b1" or "",
                tx, iy, right - hint_w - 6, iy + item_h))

        if item.separator and row < rows then
            layer(ass, "#FFFFFF", 0xE0)
            ass:draw_start()
            ass:rect_cw(x1 + 12, iy + item_h - 0.5, x2 - 12, iy + item_h + 0.5)
            ass:draw_stop()
        end
    end

    -- scrollbar
    if count > rows then
        local track_h = rows * item_h
        local thumb_h = math.max(16, track_h * rows / count)
        local thumb_y = items_y + (track_h - thumb_h) * (level.scroll / max_scroll)
        layer(ass, "#FFFFFF", 0x99)
        ass:draw_start()
        ass:round_rect_cw(x2 - 4, thumb_y, x2 - 2, thumb_y + thumb_h, 1)
        ass:draw_stop()
    end

    overlay.res_x = math.floor(res.w)
    overlay.res_y = math.floor(res.h)
    overlay.z = 2000
    overlay.data = ass.text
    overlay:update()
end

-- navigation --------------------------------------------------------------------------

local function ensure_visible(level)
    if not geo then return end
    if level.selected <= level.scroll then
        level.scroll = level.selected - 1
    elseif level.selected > level.scroll + geo.rows then
        level.scroll = level.selected - geo.rows
    end
end

local function move_selection(delta)
    local level = current()
    local count = #level.filtered
    if count == 0 then return end
    local new = level.selected + delta
    if math.abs(delta) == 1 then
        new = ((new - 1) % count) + 1 -- wrap around with arrows
    else
        new = clamp(1, new, count)
    end
    level.selected = new
    ensure_visible(level)
    render()
end

local function item_at_mouse()
    if not geo then return nil end
    if mouse.x < geo.x1 or mouse.x > geo.x2 then return nil end
    local row = math.floor((mouse.y - geo.items_y) / geo.item_h) + 1
    if row < 1 or row > geo.rows then return nil end
    local fi = current().scroll + row
    if fi > #current().filtered then return nil end
    return fi
end

local function in_panel()
    return geo and mouse.x >= geo.x1 and mouse.x <= geo.x2 and mouse.y >= geo.y1 and mouse.y <= geo.y2
end

local function on_back_arrow()
    return geo and #stack > 1 and mouse.x >= geo.x1 and mouse.x <= geo.x1 + 44
        and mouse.y >= geo.y1 and mouse.y <= geo.y1 + geo.title_h
end

local unbind

function M.close()
    if not is_open then return end
    is_open = false
    stack = {}
    root_id = nil
    geo = nil
    unbind()
    overlay.data = ""
    overlay:remove()
    if cfg.on_close then cfg.on_close() end
end

local function back()
    local level = current()
    if level and level.on_back and level.on_back() then return end
    if #stack > 1 then
        table.remove(stack)
        build(current(), true)
        render()
    else
        M.close()
    end
end

function M.refresh()
    if not is_open then return end
    for _, level in ipairs(stack) do build(level, true) end
    render()
end

local function activate(fi)
    local level = current()
    local index = level.filtered[fi or level.selected]
    if not index then return end
    local item = level.items[index]
    if item.submenu then
        M.push(item.submenu)
    elseif item.action then
        local result = item.action(item)
        if result == "keep" then
            M.refresh()
        elseif result ~= "stay" then
            M.close()
        end
    end
end

local function set_search(query)
    local level = current()
    level.search = query
    apply_filter(level)
    level.selected = 1
    level.scroll = 0
    render()
end

-- input --------------------------------------------------------------------------------

local function update_mouse()
    local x, y = mp.get_mouse_pos()
    local mx, my = x * res.sx, y * res.sy
    mouse.moved = mx ~= mouse.x or my ~= mouse.y
    mouse.x, mouse.y = mx, my
end

local function hover()
    local fi = item_at_mouse()
    if fi and fi ~= current().selected then current().selected = fi end
end

local function mouse_button(button, handler)
    return function (info)
        if info.event == "down" then
            pressed[button] = true
        elseif info.event == "up" then
            if pressed[button] then
                pressed[button] = nil
                update_mouse()
                handler()
            end
        elseif info.event == "press" then
            update_mouse()
            handler()
        end
    end
end

local bindings = {
    {"mouse_move", function ()
        update_mouse()
        if mouse.moved then hover() render() end
    end},
    {"mbtn_left", mouse_button("left", function ()
        if on_back_arrow() then return back() end
        local fi = item_at_mouse()
        if fi then
            current().selected = fi
            activate(fi)
        elseif not in_panel() then
            M.close()
        end
    end), {complex = true}},
    {"mbtn_right", mouse_button("right", back), {complex = true}},
    {"mbtn_back", back},
    {"mbtn_left_dbl", function () end},
    {"mbtn_right_dbl", function () end},
    {"mbtn_mid", function () end},
    {"wheel_up", function ()
        local level = current()
        level.scroll = math.max(0, (level.scroll or 0) - 1)
        update_mouse() hover() render()
    end, {repeatable = true}},
    {"wheel_down", function ()
        local level = current()
        level.scroll = (level.scroll or 0) + 1
        render() update_mouse() hover() render()
    end, {repeatable = true}},
    {"up", function () move_selection(-1) end, {repeatable = true}},
    {"down", function () move_selection(1) end, {repeatable = true}},
    {"pgup", function () move_selection(-(geo and geo.rows or 10)) end, {repeatable = true}},
    {"pgdwn", function () move_selection(geo and geo.rows or 10) end, {repeatable = true}},
    {"home", function () move_selection(-#current().filtered) end},
    {"end", function () move_selection(#current().filtered) end},
    {"enter", function () activate() end},
    {"kp_enter", function () activate() end},
    {"right", function ()
        local level = current()
        local item = level.items[level.filtered[level.selected] or 0]
        if item and item.submenu then activate() end
    end},
    {"left", function () if current().search == "" then back() end end},
    {"bs", function ()
        local level = current()
        if level.search ~= "" then set_search(utf8_pop(level.search)) else back() end
    end, {repeatable = true}},
    {"ctrl+bs", function () set_search("") end},
    {"esc", function ()
        if current().search ~= "" then set_search("") else M.close() end
    end},
    {"any_unicode", function (info)
        if info.event == "up" or not info.key_text then return end
        local level = current()
        if info.key_text == " " and level.search == "" then return end
        set_search(level.search .. info.key_text)
    end, {repeatable = true, complex = true}},
}

local function bind()
    for i, b in ipairs(bindings) do
        mp.add_forced_key_binding(b[1], "hybrid-menu-" .. i, b[2], b[3])
    end
end

unbind = function ()
    for i in ipairs(bindings) do
        mp.remove_key_binding("hybrid-menu-" .. i)
    end
    pressed = {}
end

-- public API -----------------------------------------------------------------------------

function M.setup(options)
    for k, v in pairs(options or {}) do cfg[k] = v end
end

function M.is_open() return is_open end

-- open a root menu; opening the same one again closes it
function M.open(id, builder)
    if is_open and root_id == id then return M.close() end
    if not is_open then
        is_open = true
        if cfg.on_open then cfg.on_open() end
        bind()
    end
    root_id = id
    stack = {new_level(builder)}
    update_resolution()
    update_mouse()
    render()
end

function M.push(builder)
    stack[#stack + 1] = new_level(builder)
    render()
end

-- replace the current level (used by the file browser to go to the parent folder)
function M.replace(builder)
    stack[#stack] = new_level(builder)
    render()
end

mp.observe_property("osd-dimensions", "native", function () if is_open then render() end end)

return M
