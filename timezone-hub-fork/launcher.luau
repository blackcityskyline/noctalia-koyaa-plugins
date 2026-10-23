--!nonstrict
-- /tz: the hub's zones inside the launcher. Empty query lists the hub rows
-- (device zone first, live times included); typing fuzzy-filters them and
-- additionally suggests zones from the full IANA list to add to the hub.
-- Mutations go through the same "koyaa_tzhub.cmd" channel the panel uses.

local NS = "koyaa_tzhub"
local PANEL_ID = "koyaa-plugins/timezone-hub-fork:panel"
local RESULT_LIMIT = 40

local function tr(key, args)
  return noctalia.tr(key, args)
end

local function sendCmd(payload)
  noctalia.state.set(NS .. ".cmd", payload)
end

local function hubRow(row, score)
  local subtitle = row.timeText
  if row.abbrev ~= nil and row.abbrev ~= "" then
    subtitle ..= " · " .. row.abbrev
  end
  subtitle ..= " · " .. row.tz
  return {
    id = "open",
    title = row.label,
    subtitle = subtitle,
    glyph = row.isDevice and "device-desktop" or "world",
    category = row.isDevice and tr("device.label") or tr("toast.title"),
    score = score,
  }
end

local function addRow(zone, score)
  return {
    id = "add:" .. zone,
    title = zone,
    subtitle = tr("launcher.add"),
    glyph = "plus",
    category = tr("toast.title"),
    score = score,
  }
end

local function panelRow(score)
  return {
    id = "open-panel",
    title = tr("launcher.open"),
    subtitle = tr("launcher.description"),
    glyph = "world",
    category = tr("toast.title"),
    score = score,
  }
end

local function publishRows(query, hubRows, allZones, knownTzs)
  local trimmed = noctalia.string.trim(query or "")
  local rows = {}

  for _, row in ipairs(hubRows or {}) do
    local score = 0
    if trimmed ~= "" then
      score = noctalia.fuzzyScore(trimmed, row.label .. " " .. row.tz)
      if score == nil then
        continue
      end
      if row.isDevice then
        score += 2
      end
    end
    table.insert(rows, hubRow(row, score))
  end

  for _, zone in ipairs(allZones or {}) do
    if type(zone) == "string" and knownTzs[zone] ~= true then
      local score = 0
      if trimmed ~= "" then
        score = noctalia.fuzzyScore(trimmed, zone)
        if score == nil then
          continue
        end
      end
      table.insert(rows, addRow(zone, score))
    end
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

  if #rows == 1 then
    -- Nothing matched outside the panel row: fallback hint (score got -1).
    launcher.setResults(query, { panelRow(2) })
    return
  end

  launcher.setResults(query, rows)
end

function onQuery(query)
  local rows = noctalia.state.get(NS .. ".rows")
  local allZones = noctalia.state.get(NS .. ".all_zones")
  local known = {}

  if type(rows) == "table" then
    for _, r in ipairs(rows) do
      if type(r.tz) == "string" and r.tz ~= "" then
        known[r.tz] = true
      end
    end
    publishRows(query, rows, allZones, known)
    return
  end

  -- Hub rows not published yet: still allow pure zone search (plain fallback).
  local trimmed = noctalia.string.trim(query or "")
  if trimmed ~= "" then
    publishRows(query, {}, allZones, known)
  else
    launcher.setResults(query, {
      { id = "", title = tr("launcher.loading"), glyph = "loader" },
      panelRow(2),
    })
  end
end

function onActivate(id)
  if type(id) ~= "string" or id == "" then
    return
  end
  if id == "open" or id == "open-panel" then
    noctalia.togglePanel(PANEL_ID)
    return
  end
  local zone = string.match(id, "^add:(.+)$")
  if zone ~= nil then
    sendCmd({ op = "add", tz = zone })
    noctalia.notify(tr("toast.title"), tr("launcher.added", { zone = zone }))
  end
end
