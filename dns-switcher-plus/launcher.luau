--!nonstrict
-- /dns: provider list inside the launcher. Activating a provider applies it
-- through the same "apply_request" state channel the panel uses. The service
-- publishes "dns_state" (nonce/current/list/changing), so rows come from there.

local PANEL_ID = "koyaa-plugins/dns-switcher-plus:panel"
local STATE_KEY = "dns_state"
local REQUEST_KEY = "apply_request"

local RESULT_LIMIT = 40

local function tr(key, args)
  return noctalia.tr(key, args)
end

local function bumpRequest(id)
  local prev = noctalia.state.get(REQUEST_KEY)
  local nonce = (type(prev) == "table" and tonumber(prev.nonce) or 0) + 1
  noctalia.state.set(REQUEST_KEY, { nonce = nonce, id = id })
end

local function providerRow(p, score)
  local snap = noctalia.state.get(STATE_KEY)
  local isCurrent = type(snap) == "table" and type(snap.current) == "table" and snap.current.id == p.id
  local subtitle = p.ip ~= "" and p.ip or tr("launcher.auto")
  if isCurrent then
    subtitle ..= " · " .. tr("launcher.current")
  end
  return {
    id = "apply:" .. p.id,
    title = p.label,
    subtitle = subtitle,
    glyph = isCurrent and "check" or p.glyph,
    category = tr("title"),
    score = score,
  }
end

local function panelRow(score)
  return {
    id = "open-panel",
    title = tr("launcher.open"),
    subtitle = tr("launcher.description"),
    glyph = "world",
    category = tr("title"),
    score = score,
  }
end

local function publish(query)
  local snap = noctalia.state.get(STATE_KEY)
  if type(snap) ~= "table" or type(snap.list) ~= "table" then
    launcher.setResults(query, panelRow(0))
    return
  end

  local rows = {}
  local currentId = type(snap.current) == "table" and snap.current.id or nil
  local trimmed = noctalia.string.trim(query or "")
  for _, p in ipairs(snap.list) do
    local score = 0
    if trimmed ~= "" then
      score = noctalia.fuzzyScore(trimmed, p.label .. " " .. (p.ip or ""))
      if score == nil then
        continue
      end
    else
      -- Unfiltered: current provider first, then the rest in list order.
      score = p.id == currentId and 3 or 1
    end
    table.insert(rows, providerRow(p, score))
  end
  table.insert(rows, panelRow(if trimmed == "" then 1 else noctalia.fuzzyScore(trimmed, tr("launcher.open") .. " " .. tr("launcher.description")) or -1))
  table.sort(rows, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    return a.title < b.title
  end)
  while #rows > RESULT_LIMIT do
    table.remove(rows)
  end

  if type(snap.changing) == "boolean" and snap.changing then
    table.insert(rows, 1, { id = "", title = tr("launcher.applying"), glyph = "loader" })
  end

  launcher.setResults(query, rows)
end

function onQuery(query)
  publish(query)
end

function onActivate(id)
  if type(id) ~= "string" or id == "" then
    return
  end
  if id == "open-panel" then
    noctalia.togglePanel(PANEL_ID)
    return
  end
  local pid = string.match(id, "^apply:(.+)$")
  if pid ~= nil then
    bumpRequest(pid)
  end
end
