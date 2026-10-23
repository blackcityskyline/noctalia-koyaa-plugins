--!nonstrict
-- dns-switcher — bar widget for koyaa-plugins/dns-switcher-plus

local STATE_KEY = "dns_state"
local GLYPH_UNKNOWN = "globe"

local snapshot = nil

local function tr(key, args)
    return noctalia.tr(key, args)
end

local function setLabel(text)
    if noctalia.getConfig("show_label") == false then
        barWidget.setText("")
    else
        barWidget.setText(text)
    end
end

local function render()
    local s = snapshot
    if s == nil or (s.current == nil and s.error == nil) then
        barWidget.setGlyph(GLYPH_UNKNOWN)
        barWidget.setGlyphColor("")
        barWidget.setColor("")
        setLabel(tr("status_checking"))
        barWidget.clearTooltip()
        return
    end

    if s.changing == true then
        barWidget.setGlyph("refresh")
        barWidget.setGlyphColor("secondary")
        barWidget.setColor("secondary")
        setLabel(tr("status_switching"))
        barWidget.setTooltip(tr("tooltip_switching"))
        return
    end

    if s.error ~= nil then
        barWidget.setGlyph(GLYPH_UNKNOWN)
        barWidget.setGlyphColor("error")
        barWidget.setColor("error")
        setLabel(s.error)
        barWidget.clearTooltip()
        return
    end

    local colorNonDefault = noctalia.getConfig("color_non_default")
    if colorNonDefault == nil then colorNonDefault = true end

    local activeRole = noctalia.getConfig("active_color_role")
    if type(activeRole) ~= "string" or activeRole == "" then
        activeRole = "primary"
    end

    barWidget.setGlyph(s.current.glyph or GLYPH_UNKNOWN)

    if s.current.id ~= "default" and colorNonDefault then
        barWidget.setGlyphColor(activeRole)
        barWidget.setColor(activeRole)
    else
        barWidget.setGlyphColor("")
        barWidget.setColor("")
    end

    setLabel(s.current.label)

    local servers = s.current.ip
    if servers == "" or servers == nil then
        servers = (s.servers and s.servers ~= "") and s.servers or tr("status_auto")
    end

    barWidget.setTooltip({
        { key = "DNS", value = s.current.label },
        { key = "Servers", value = servers },
        { key = "Actions", value = "click: panel  ·  right: apply default" },
    })
end

noctalia.state.watch(STATE_KEY, function(value)
    if type(value) == "table" then
        snapshot = value
        render()
    end
end)

snapshot = noctalia.state.get(STATE_KEY)
render()
