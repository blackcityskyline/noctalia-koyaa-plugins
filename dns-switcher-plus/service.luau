--!nonstrict
local STATE_KEY = "dns_state"
local REQUEST_KEY = "apply_request"

local BUILTIN = {
    { id = "google",     label = "Google",     ip = "8.8.8.8 8.8.4.4",               glyph = "brand-google" },
    { id = "cloudflare", label = "Cloudflare", ip = "1.1.1.1 1.0.0.1",               glyph = "cloud" },
    { id = "opendns",    label = "OpenDNS",    ip = "208.67.222.222 208.67.220.220", glyph = "world" },
    { id = "adguard",    label = "AdGuard",    ip = "94.140.14.14 94.140.15.15",     glyph = "shield-check" },
    { id = "quad9",      label = "Quad9",      ip = "9.9.9.9 149.112.112.112",       glyph = "lock" },
}
local GLYPH_DEFAULT = "router"
local GLYPH_AUTO = "bolt"
local GLYPH_UNKNOWN = "globe"

local current = nil
local lastSeen = ""
local conName = ""
local errMsg = nil
local pollTicks = 0
local changing = false
local checkInFlight = false
local stateNonce = 0

local function cfg(key) return noctalia.getConfig(key) end
local function tr(key, args) return noctalia.tr(key, args) end
local function trim(v) return (v:gsub("^%s+", ""):gsub("%s+$", "")) end

local function pollSeconds()
    return math.max(2, tonumber(cfg("poll_seconds")) or 10)
end

local function isDnscryptMode()
    return cfg("engine_mode") == "dnscrypt"
end

local function getPrivTool()
    local tool = cfg("privilege_tool")
    if tool == "run0" then return "run0" end
    return "pkexec"
end

local function providerList()
    local list = {}
    table.insert(list, { id = "default", label = tr("status_default"), ip = "", glyph = GLYPH_DEFAULT })
    if isDnscryptMode() then
        table.insert(list, { id = "auto", label = "DNSCrypt Auto (Fastest)", ip = "127.0.0.1", glyph = GLYPH_AUTO })
    end
    for _, p in ipairs(BUILTIN) do table.insert(list, p) end
    return list
end

local function publish()
    stateNonce += 1
    noctalia.state.set(STATE_KEY, {
        nonce = stateNonce,
        current = current,
        servers = lastSeen,
        conName = conName,
        changing = changing,
        error = errMsg,
        list = providerList(),
    })
end

local DETECT_CMD = [[
ACT=$(LC_ALL=C nmcli -t -f TYPE,DEVICE,UUID,NAME connection show --active 2>/dev/null)
LINE=$(printf '%s\n' "$ACT" | grep -E '^(802-11-wireless|802-3-ethernet):' | head -n 1)
[ -n "$LINE" ] || LINE=$(printf '%s\n' "$ACT" | grep -v '^loopback:' | head -n 1)
[ -n "$LINE" ] || { echo 'ERR=noconn'; exit 0; }
DEV=$(printf '%s' "$LINE" | cut -d: -f2)
UUID=$(printf '%s' "$LINE" | cut -d: -f3)
echo "NAME=$(printf '%s' "$LINE" | cut -d: -f4-)"
echo "CFG=$(LC_ALL=C nmcli -g ipv4.dns connection show uuid "$UUID" 2>/dev/null)"
echo "AUTO=$(LC_ALL=C nmcli -g ipv4.ignore-auto-dns connection show uuid "$UUID" 2>/dev/null)"
echo "RUN=$(nmcli -g IP4.DNS device show "$DEV" 2>/dev/null | tr '\n' ' ')"
]]

local function updateDnsState(stdout)
    local fields = {}
    for line in stdout:gmatch("[^\n]+") do
        local k, v = line:match("^(%u+)=(.*)$")
        if k then fields[k] = v end
    end

    if fields.ERR == "noconn" then
        current = nil
        errMsg = tr("err_no_connection")
        return
    end
    errMsg = nil
    conName = fields.NAME or ""
    lastSeen = fields.RUN or ""

    if fields.AUTO ~= "yes" or fields.CFG == "" then
        current = { id = "default", label = tr("status_default"), ip = "", glyph = GLYPH_DEFAULT }
        return
    end

    if isDnscryptMode() and fields.CFG == "127.0.0.1" then
        local rawPath = cfg("dnscrypt_config") or "/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
        local text = noctalia.readFile(rawPath) or ""
        local rawServers = text:match("server_names%s*=%s*%[([^%]]*)%]")
        if rawServers ~= nil then
            rawServers = trim(rawServers)
            if rawServers == "" then
                current = { id = "auto", label = "DNSCrypt Auto (Fastest)", ip = "127.0.0.1", glyph = GLYPH_AUTO }
                return
            end
            local serverName = rawServers:match("^'([^']+)'$") or rawServers:match('^"([^"]+)"$')
            if serverName then
                for _, provider in ipairs(BUILTIN) do
                    if provider.id == serverName then
                        current = provider
                        return
                    end
                end
                current = { id = "dnscrypt:" .. serverName, label = "DNSCrypt (" .. serverName .. ")", ip = "127.0.0.1", glyph = "shield-check" }
                return
            end
        end
    end

    for _, provider in ipairs(BUILTIN) do
        if fields.CFG == provider.ip then
            current = provider
            return
        end
    end
    current = { id = "custom", label = tr("status_custom", { ip = fields.CFG }), ip = fields.CFG, glyph = GLYPH_UNKNOWN }
end

local function pollNow()
    if checkInFlight or changing then return end
    checkInFlight = true
    noctalia.runAsync(DETECT_CMD, function(result)
        checkInFlight = false
        if result.exitCode == 0 and not result.timedOut then
            updateDnsState(result.stdout)
        end
        publish()
    end, 4000)
end

local function apply(provider)
    if changing then return end
    local privTool = getPrivTool()
    local cfgPath = cfg("dnscrypt_config") or "/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
    local svcName = cfg("dnscrypt_service") or "dnscrypt-proxy.service"

    local bashScript = ""

    if provider.id == "default" then
        bashScript = string.format([[
            %s sh -c 'ACT=$(LC_ALL=C nmcli -t -f TYPE,DEVICE,UUID connection show --active 2>/dev/null | grep -E "^(802-11-wireless|802-3-ethernet):" | head -n 1); DEV=$(echo "$ACT" | cut -d: -f2); UUID=$(echo "$ACT" | cut -d: -f3); nmcli con mod "$UUID" ipv4.dns "" ipv4.ignore-auto-dns no && nmcli device reapply "$DEV"'
        ]], privTool)
    elseif isDnscryptMode() then
        local serverValue = (provider.id == "auto") and "[]" or string.format("['%s']", provider.id)

        bashScript = string.format([[
            RAW_CONF="%s"
            REAL_CONF=$(readlink -f "$RAW_CONF" 2>/dev/null || echo "$RAW_CONF")
            
            if [ -w "$REAL_CONF" ]; then
                sed -i "s/^server_names = .*/server_names = %s/" "$REAL_CONF"
            else
                %s sed -i --follow-symlinks "s/^server_names = .*/server_names = %s/" "$RAW_CONF"
            fi

            %s sh -c 'systemctl restart %s && ACT=$(LC_ALL=C nmcli -t -f TYPE,DEVICE,UUID connection show --active 2>/dev/null | grep -E "^(802-11-wireless|802-3-ethernet):" | head -n 1); DEV=$(echo "$ACT" | cut -d: -f2); UUID=$(echo "$ACT" | cut -d: -f3); nmcli con mod "$UUID" ipv4.dns "127.0.0.1" ipv4.ignore-auto-dns yes && nmcli device reapply "$DEV"'
        ]], cfgPath, serverValue, privTool, serverValue, privTool, svcName)
    else
        bashScript = string.format([[
            %s sh -c 'ACT=$(LC_ALL=C nmcli -t -f TYPE,DEVICE,UUID connection show --active 2>/dev/null | grep -E "^(802-11-wireless|802-3-ethernet):" | head -n 1); DEV=$(echo "$ACT" | cut -d: -f2); UUID=$(echo "$ACT" | cut -d: -f3); nmcli con mod "$UUID" ipv4.dns "%s" ipv4.ignore-auto-dns yes && nmcli device reapply "$DEV"'
        ]], privTool, provider.ip)
    end

    changing = true
    publish()

    noctalia.runAsync(bashScript, function(result)
        changing = false
        if result.exitCode == 0 then
            noctalia.notify(tr("title"), tr("applied", { name = provider.label }))
        else
            noctalia.notifyError(tr("title"), tr("err_apply_failed"))
        end
        publish()
        pollNow()
    end, 20000)
end

local function handleApplyId(payload)
    for _, p in ipairs(providerList()) do
        if p.id == payload then apply(p) return end
    end
end

function onIpc(event, payload)
    if event == "poll" then 
        pollNow()
    elseif event == "apply" then
        handleApplyId(payload)
    end
end

noctalia.state.watch(REQUEST_KEY, function(val)
    if type(val) == "table" and val.id then
        handleApplyId(val.id)
    end
end)

function update()
    pollTicks += 1
    if pollTicks >= pollSeconds() then
        pollTicks = 0
        pollNow()
    end
end

noctalia.setUpdateInterval(1000)
publish()
pollNow()
