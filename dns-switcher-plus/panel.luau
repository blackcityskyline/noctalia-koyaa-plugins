--!nonstrict
local STATE_KEY = "dns_state"
local REQUEST_KEY = "apply_request"
local snapshot = nil

local function tr(key, args) return noctalia.tr(key, args) end

local function requestApply(id)
    if snapshot == nil or snapshot.changing then return end
    local prev = noctalia.state.get(REQUEST_KEY)
    local nonce = (type(prev) == "table" and tonumber(prev.nonce) or 0) + 1
    
    noctalia.state.set(REQUEST_KEY, { nonce = nonce, id = id })
    noctalia.sendIpc("koyaa-plugins/dns-switcher-plus:service", "apply", id)
end

local function providerRow(entry)
    local active = snapshot.current ~= nil and snapshot.current.id == entry.id
    local text = entry.label .. (entry.ip ~= "" and ("  ·  " .. entry.ip) or "")
    return ui.button({
        key = "dns-" .. entry.id,
        glyph = entry.glyph,
        text = text,
        variant = active and "primary" or "ghost",
        contentAlign = "start",
        onClick = function() if not active then requestApply(entry.id) end end,
    })
end

local function render()
    local children = {
        ui.row({ gap = 8, align = "center" }, {
            ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold" }),
            ui.spacer({ flexGrow = 1 }),
            ui.button({ glyph = "settings", variant = "ghost", onClick = function() noctalia.openSettings() end }),
            ui.button({ glyph = "close", variant = "ghost", onClick = function() panel.close() end }),
        }),
    }

    if snapshot == nil or snapshot.list == nil then
        table.insert(children, ui.label({ text = tr("status_checking") }))
    else
        local rows = {}
        for _, entry in ipairs(snapshot.list) do
            table.insert(rows, providerRow(entry))
        end
        table.insert(children, ui.scroll({ flexGrow = 1, gap = 4 }, rows))
    end

    panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, children))
end

function onOpen()
    snapshot = noctalia.state.get(STATE_KEY)
    render()
end

noctalia.state.watch(STATE_KEY, function(val)
    if type(val) == "table" then
        snapshot = val
        render()
    end
end)
