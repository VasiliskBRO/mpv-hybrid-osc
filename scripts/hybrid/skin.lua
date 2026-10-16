-- Skins for the hybrid OSC: where every element of the bottom bar is, as data.
--
-- A skin is a JSON file in ~~/skins/<name>.json:
--   { "name": "...", "height": 123, "items": [ item, ... ] }
--   height - height of the bar background (virtual px, the window is 720 high)
-- Item fields:
--   id        element name (see ELEMENTS in main.lua) or "custom_*" for user-made objects
--   anchor    "left" | "center" | "right" - x is counted from that point of the window
--             "stretch" - the item spans the window: x = left margin, r = right margin
--   x, w      left edge offset from the anchor and width (not used by "stretch")
--   bottom, h distance from the bottom of the window to the item's bottom edge, height
--   priority  when items overlap (narrow window), the one with the lower priority is hidden;
--             items without priority are never hidden this way
--   hide_below  hide the item when the window is narrower than this (virtual px)
--   collapse  when this item is hidden, items above it move down by this much
--             and the bar gets lower (used for the chapter line)

local utils = require "mp.utils"

local M = {}

M.DEFAULT_NAME = "standard"

-- the look of the classic hybrid layout at 1280x720 with a chapter shown
M.DEFAULT = {
    name = "Стандарт",
    height = 123,
    items = {
        {id = "title",         anchor = "stretch", x = 25,   r = 25, bottom = 99, h = 24},
        {id = "chapter_title", anchor = "stretch", x = 26,   r = 34, bottom = 78, h = 16, collapse = 19},
        {id = "seekbar",       anchor = "stretch", x = 15,   r = 15, bottom = 51, h = 18},
        {id = "menu",          anchor = "left",    x = 25,   w = 24, bottom = 18, h = 24, priority = 6},
        {id = "sub_track",     anchor = "left",    x = 70,   w = 24, bottom = 18, h = 24, priority = 5},
        {id = "time_codes",    anchor = "left",    x = 115,  w = 90, bottom = 22, h = 16, priority = 3},
        {id = "playlist_prev", anchor = "center",  x = -135, w = 30, bottom = 18, h = 24, priority = 10},
        {id = "jump_backward", anchor = "center",  x = -75,  w = 30, bottom = 18, h = 24, priority = 10},
        {id = "play_pause",    anchor = "center",  x = -22.5, w = 45, bottom = 16, h = 28, priority = 10},
        {id = "jump_forward",  anchor = "center",  x = 45,   w = 30, bottom = 18, h = 24, priority = 10},
        {id = "playlist_next", anchor = "center",  x = 105,  w = 30, bottom = 18, h = 24, priority = 10},
        {id = "speed_ruler",   anchor = "right",   x = -402, w = 160, bottom = 11, h = 38, priority = 1},
        {id = "shuffle",       anchor = "right",   x = -229, w = 24, bottom = 18, h = 24, priority = 2},
        {id = "file_loop",     anchor = "right",   x = -184, w = 24, bottom = 18, h = 24, priority = 4},
        {id = "playlist",      anchor = "right",   x = -139, w = 24, bottom = 18, h = 24, priority = 7},
        {id = "pip",           anchor = "right",   x = -94,  w = 24, bottom = 18, h = 24, priority = 8},
        {id = "fullscreen",    anchor = "right",   x = -49,  w = 24, bottom = 18, h = 24, priority = 9},
    },
}

local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return out
end
M.copy = copy

function M.dir()
    -- backslashes: "mkdir" of cmd.exe takes "/" for a switch
    return (mp.command_native({"expand-path", "~~/skins"}):gsub("/", "\\"))
end

function M.path(name)
    return M.dir() .. "\\" .. name .. ".json"
end

-- keep only sane items, fill in missing numbers
local function normalize(skin)
    if type(skin) ~= "table" or type(skin.items) ~= "table" then return nil end
    local items = {}
    for _, item in ipairs(skin.items) do
        if type(item) == "table" and type(item.id) == "string" then
            item.anchor = ({left = 1, center = 1, right = 1, stretch = 1})[item.anchor] and item.anchor or "left"
            item.x = tonumber(item.x) or 0
            item.bottom = tonumber(item.bottom) or 0
            item.h = math.max(4, tonumber(item.h) or 24)
            item.priority = tonumber(item.priority)
            item.hide_below = tonumber(item.hide_below)
            item.collapse = tonumber(item.collapse)
            if item.anchor == "stretch" then
                item.r = tonumber(item.r) or 0
            else
                item.w = math.max(4, tonumber(item.w) or 24)
            end
            items[#items + 1] = item
        end
    end
    skin.items = items
    skin.height = math.max(0, tonumber(skin.height) or M.DEFAULT.height)
    skin.name = type(skin.name) == "string" and skin.name or nil
    return skin
end

-- load a skin by file name (without .json); falls back to the built-in default
function M.load(name)
    name = name or M.DEFAULT_NAME
    local file = io.open(M.path(name), "rb")
    if file then
        local text = file:read("*a")
        file:close()
        local skin = normalize(utils.parse_json(text or ""))
        if skin then return skin, true end
        mp.msg.warn("skin '" .. name .. "' is broken, using the standard one")
    end
    return copy(M.DEFAULT), false
end

-- JSON with a stable key order and one item per line, so the file stays readable
local KEY_ORDER = {"id", "anchor", "x", "w", "r", "bottom", "h", "priority", "hide_below", "collapse"}

local function json_value(value)
    if type(value) == "number" then
        if value == math.floor(value) then return string.format("%d", value) end
        return (string.format("%.2f", value):gsub("0+$", ""))
    end
    return utils.format_json(value)
end

local function json_object(object, order)
    local parts, seen = {}, {}
    for _, key in ipairs(order) do
        if object[key] ~= nil then
            parts[#parts + 1] = string.format("%q: %s", key, json_value(object[key]))
            seen[key] = true
        end
    end
    local rest = {}
    for key in pairs(object) do
        if not seen[key] then rest[#rest + 1] = key end
    end
    table.sort(rest)
    for _, key in ipairs(rest) do
        parts[#parts + 1] = string.format("%q: %s", key, json_value(object[key]))
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

function M.encode(skin)
    local lines = {"{"}
    lines[#lines + 1] = string.format('  "name": %s,', utils.format_json(skin.name or ""))
    lines[#lines + 1] = string.format('  "height": %s,', json_value(skin.height or M.DEFAULT.height))
    lines[#lines + 1] = '  "items": ['
    for i, item in ipairs(skin.items) do
        lines[#lines + 1] = "    " .. json_object(item, KEY_ORDER) .. (i < #skin.items and "," or "")
    end
    lines[#lines + 1] = "  ]"
    lines[#lines + 1] = "}"
    return table.concat(lines, "\n") .. "\n"
end

function M.save(name, skin)
    local dir = M.dir()
    if not utils.file_info(dir) then
        mp.command_native({name = "subprocess", playback_only = false, capture_stdout = true,
            args = {"cmd", "/c", "mkdir", dir}})
    end
    local path = M.path(name)
    local tmp = path .. ".tmp"
    local file, err = io.open(tmp, "wb")
    if not file then return false, err end
    file:write(M.encode(skin))
    file:close()
    os.remove(path)
    local ok, rename_err = os.rename(tmp, path)
    if not ok then return false, rename_err end
    return true
end

return M
