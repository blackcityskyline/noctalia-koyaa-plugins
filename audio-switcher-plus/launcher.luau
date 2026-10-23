--!nonstrict
-- /audio: switch devices and manage output groups from the launcher.
-- Rows come from the service snapshot ("audio_switcher_snapshot") and share
-- the panel's command channel ("audio_switcher_command").
-- Normal mode: activate = set_output / set_input; unconnected Bluetooth
-- hardware is connected first; existing groups get a disband row.
-- Group mode (entered from the "New group" row): usable outputs toggle
-- selection, "Create group (N)" sends create_output_group with the ids.
-- Selection survives onQuery/onActivate and resets after grouping.

local PANEL_ID = "koyaa-plugins/audio-switcher-plus:audio-switcher-plus"
local SNAPSHOT_KEY = "audio_switcher_snapshot"
local COMMAND_KEY = "audio_switcher_command"
local RESULT_LIMIT = 40

local requestCounter = 0
local groupMode = false
local selectedIds = {}

local function tr(key, args)
  return noctalia.tr(key, args)
end

local function sendCommand(action, values)
  requestCounter += 1
  local cmd = { action = action, requestId = "launcher-" .. tostring(requestCounter) }
  if type(values) == "table" then
    for k, v in pairs(values) do
      cmd[k] = v
    end
  end
  noctalia.state.set(COMMAND_KEY, cmd)
end

local function clearSelection()
  selectedIds = {}
  groupMode = false
end

local function usableForGroup(d)
  return d.available == true
    and d.group ~= true
    and type(d.targetName) == "string"
    and d.targetName ~= ""
end

local function subtitleFor(d, isCurrent, extra)
  local text = tostring(d.description or d.name or d.id or "")
  if isCurrent then
    text ..= " · " .. tr("launcher.current")
  end
  if d.bluetooth == true and d.available == false then
    text ..= " · " .. tr("launcher.bt_disconnected")
  end
  if extra ~= nil and extra ~= "" then
    text ..= " · " .. extra
  end
  return text
end

local function deviceRow(d, score, idOverride, extra)
  return {
    id = idOverride,
    title = tostring(d.name or d.id),
    subtitle = subtitleFor(d, d.active == true, extra),
    glyph = idOverride == nil and d.active == true and "check"
      or (d.direction == "input" and "microphone" or tostring(d.icon or "volume")),
    score = score,
  }
end

local function panelRow(score)
  return {
    id = "open-panel",
    title = tr("launcher.open"),
    subtitle = tr("launcher.description"),
    glyph = "switch-horizontal",
    score = score,
  }
end

-- ── Normal mode ─────────────────────────────────────────────────────────────

local function publishNormal(query, snap, trimmed)
  local rows = {}

  local function scoreDevice(d)
    local hay = tostring(d.name or "") .. " " .. tostring(d.description or "")
    if trimmed ~= "" then
      local score = noctalia.fuzzyScore(trimmed, hay)
      if score == nil then
        return nil
      end
      if d.active == true then
        score += 2
      end
      return score
    end
    return d.active == true and 3 or 1
  end

  for _, d in ipairs(snap.outputs or {}) do
    if type(d) == "table" and d.hidden ~= true then
      local score = scoreDevice(d)
      if score ~= nil then
        if d.group == true then
          local members = type(d.groupMembers) == "table" and table.concat(d.groupMembers, ", ") or ""
          table.insert(rows, deviceRow(d, score, "ungroup:" .. tostring(d.id), tr("launcher.group_members", { members = members })))
        elseif d.bluetooth == true and d.available == false then
          table.insert(rows, deviceRow(d, score, "bt:" .. tostring(d.address), nil))
        else
          table.insert(rows, deviceRow(d, score, "out:" .. tostring(d.id), nil))
        end
      end
    end
  end

  for _, d in ipairs(snap.inputs or {}) do
    if type(d) == "table" and d.hidden ~= true then
      local score = scoreDevice(d)
      if score ~= nil then
        table.insert(rows, deviceRow(d, score, "in:" .. tostring(d.id), nil))
      end
    end
  end

  -- Connected Bluetooth devices: explicit reconnect row (disconnect + connect).
  local reconnected = {}
  for _, d in ipairs(snap.outputs or {}) do
    if type(d) == "table" and d.bluetooth == true and d.available == true
      and type(d.address) == "string" and d.address ~= "" and reconnected[d.address] ~= true then
      reconnected[d.address] = true
      table.insert(rows, {
        id = "recon:" .. d.address,
        title = tr("launcher.reconnect", { name = tostring(d.name or "") }),
        subtitle = tr("launcher.reconnect_hint"),
        glyph = "refresh",
        score = trimmed == "" and 1 or (noctalia.fuzzyScore(trimmed, "reconnect " .. tostring(d.name or "")) or -1),
      })
    end
  end

  if #rows == 0 then
    launcher.setResults(query, {
      { id = "", title = tr("launcher.no_devices"), glyph = "search-off" },
      panelRow(2),
    })
    return
  end

  -- Grouping entry: needs >= 2 usable outputs.
  local usable = 0
  for _, d in ipairs(snap.outputs or {}) do
    if type(d) == "table" and d.hidden ~= true and usableForGroup(d) then
      usable += 1
    end
  end
  if usable >= 2 then
    table.insert(rows, {
      id = "mode:group",
      title = tr("launcher.new_group"),
      subtitle = tr("launcher.new_group_hint"),
      glyph = "stack-2",
      score = trimmed == "" and 1 or (noctalia.fuzzyScore(trimmed, tr("launcher.new_group") .. " " .. tr("launcher.new_group_hint")) or -1),
    })
  end

  local panel = panelRow(if trimmed == "" then 1 else noctalia.fuzzyScore(trimmed, tr("launcher.open") .. " " .. tr("launcher.description")) or -1)
  table.insert(rows, panel)

  table.sort(rows, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    return a.title < b.title
  end)
  while #rows > RESULT_LIMIT do
    table.remove(rows)
  end

  if snap.busy == true then
    table.insert(rows, 1, { id = "", title = tr("launcher.busy"), glyph = "loader" })
  end

  launcher.setResults(query, rows)
end

-- ── Group mode ──────────────────────────────────────────────────────────────

local function publishGroupMode(query, snap, trimmed)
  local rows = {}
  local selectedCount = 0

  for _, d in ipairs(snap.outputs or {}) do
    if type(d) == "table" and d.hidden ~= true and usableForGroup(d) then
      local chosen = selectedIds[tostring(d.id)] == true
      if chosen then
        selectedCount += 1
      end
      local score = 0
      local hay = tostring(d.name or "") .. " " .. tostring(d.description or "")
      if trimmed ~= "" then
        score = noctalia.fuzzyScore(trimmed, hay)
        if score == nil then
          continue
        end
      else
        score = selectedIds[tostring(d.id)] == true and 3 or 1
      end
      local row = deviceRow(d, score, "sel:" .. tostring(d.id), chosen and tr("launcher.selected") or nil)
      if chosen then
        row.glyph = "check"
      end
      table.insert(rows, row)
    end
  end

  if selectedCount >= 2 then
    table.insert(rows, {
      id = "do-group",
      title = tr("actions.create_group", { count = selectedCount }),
      subtitle = tr("launcher.create_group_hint"),
      glyph = "check",
      score = 5,
    })
  end

  table.insert(rows, {
    id = "back",
    title = tr("launcher.back"),
    subtitle = "",
    glyph = "chevron-left",
    score = 0,
  })

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

  launcher.setResults(query, rows)
end

function onQuery(query)
  local snap = noctalia.state.get(SNAPSHOT_KEY)
  if type(snap) ~= "table" or type(snap.outputs) ~= "table" then
    launcher.setResults(query, { panelRow(0) })
    return
  end

  if snap.loading == true then
    launcher.setResults(query, {
      { id = "", title = tr("launcher.loading"), glyph = "loader" },
      panelRow(2),
    })
    return
  end

  local trimmed = noctalia.string.trim(query or "")
  if groupMode then
    publishGroupMode(query, snap, trimmed)
  else
    publishNormal(query, snap, trimmed)
  end
end

function onActivate(id)
  if type(id) ~= "string" or id == "" then
    return
  end

  if id == "open-panel" then
    noctalia.togglePanel(PANEL_ID)
    clearSelection()
    return
  end

  if id == "mode:group" then
    groupMode = true
    selectedIds = {}
    return
  end

  if id == "back" then
    clearSelection()
    return
  end

  if id == "do-group" then
    local ids = {}
    for key, chosen in pairs(selectedIds) do
      if chosen then
        table.insert(ids, key)
      end
    end
    if #ids >= 2 then
      sendCommand("create_output_group", { ids = ids })
      clearSelection()
    end
    return
  end

  local selId = string.match(id, "^sel:(.+)$")
  if selId ~= nil then
    selectedIds[selId] = selectedIds[selId] == true and false or true
    return
  end

  local deviceId = string.match(id, "^ungroup:(.+)$")
  if deviceId ~= nil then
    sendCommand("remove_output_group", { id = deviceId })
    return
  end

  deviceId = string.match(id, "^out:(.+)$")
  if deviceId ~= nil then
    sendCommand("set_output", { id = deviceId })
    return
  end

  deviceId = string.match(id, "^in:(.+)$")
  if deviceId ~= nil then
    sendCommand("set_input", { id = deviceId })
    return
  end

  local address = string.match(id, "^bt:(.+)$")
  if address ~= nil then
    sendCommand("connect_bluetooth", { address = address })
    return
  end

  address = string.match(id, "^recon:(.+)$")
  if address ~= nil then
    sendCommand("reconnect_bluetooth", { address = address })
  end
end
