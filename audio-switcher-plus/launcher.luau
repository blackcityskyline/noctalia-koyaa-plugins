--!nonstrict
-- /as: switch devices and manage output groups from the launcher — single
-- screen, no stage machine. Rows come from the service snapshot
-- ("audio_switcher_snapshot"); every action shares the panel's command
-- channel ("audio_switcher_command").
--   output/input rows          -> set_output / set_input (a group sink is a
--                                 valid default target too)
--   unconnected Bluetooth row  -> connect_bluetooth
--   connected Bluetooth row    -> plus a separate reconnect row
--   "Disband group" row        -> remove_output_group
--   "Group + <name>" rows      -> toggle selection; it survives closing the
--                                 launcher, so devices can be picked across
--                                 re-opens; "Create group (N)" sends
--                                 create_output_group once 2+ are picked.
-- Hidden devices stay in the panel. The snapshot watch repaints rows created
-- asynchronously (new group, connected BT) without retyping.

local PANEL_ID = "koyaa-plugins/audio-switcher-plus:audio-switcher-plus"
local SNAPSHOT_KEY = "audio_switcher_snapshot"
local COMMAND_KEY = "audio_switcher_command"
local RESULT_KEY = "audio_switcher_result"
local RESULT_LIMIT = 40

local requestCounter = 0
local selectedIds = {}
local lastQuery = ""
local lastResult = nil

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

local function usableForGroup(d)
  return d.available == true
    and d.group ~= true
    and type(d.targetName) == "string"
    and d.targetName ~= ""
end

local function subtitleFor(d, isCurrent, extra, tag)
  local text = tostring(d.description or d.name or d.id or "")
  if isCurrent then
    text ..= " · " .. tr("launcher.current")
  end
  if type(tag) == "string" and tag ~= "" then
    text ..= " · " .. tag
  end
  if d.bluetooth == true and d.available == false then
    text ..= " · " .. tr("launcher.bt_disconnected")
  end
  if extra ~= nil and extra ~= "" then
    text ..= " · " .. extra
  end
  return text
end

local function deviceRow(id, title, subtitle, glyph, score)
  return {
    id = id,
    title = title,
    subtitle = subtitle,
    glyph = glyph,
    score = score,
  }
end

local function switchIdFor(d)
  if d.bluetooth == true and d.available == false then
    return "bt:" .. tostring(d.address)
  end
  return "out:" .. tostring(d.id)
end

local function publish(query, snap, trimmed)
  local rows = {}

  local function scoreFor(hay, activeBonus)
    if trimmed ~= "" then
      local score = noctalia.fuzzyScore(trimmed, hay)
      if score == nil then
        return nil
      end
      if activeBonus then
        score += 2
      end
      return score
    end
    return activeBonus and 3 or 1
  end

  -- Switch rows: outputs (incl. group sinks and unconnected BT) + inputs.
  -- Glyph stays the device's own icon so a current input and a current output
  -- remain visually distinct; "current" shows in the subtitle and every row is
  -- direction-tagged (built-in input/output can share one description text).
  for _, d in ipairs(snap.outputs or {}) do
    if type(d) == "table" and d.hidden ~= true then
      local hay = tostring(d.name or "") .. " " .. tostring(d.description or "")
      local score = scoreFor(hay, d.active == true)
      if score ~= nil then
        table.insert(rows, deviceRow(
          switchIdFor(d),
          tostring(d.name or d.id),
          subtitleFor(d, d.active == true, nil, "output"),
          tostring(d.icon or "volume"),
          score
        ))
      end
    end
  end

  for _, d in ipairs(snap.inputs or {}) do
    if type(d) == "table" and d.hidden ~= true then
      local hay = tostring(d.name or "") .. " " .. tostring(d.description or "")
      local score = scoreFor(hay, d.active == true)
      if score ~= nil then
        table.insert(rows, deviceRow(
          "in:" .. tostring(d.id),
          tostring(d.name or d.id),
          subtitleFor(d, d.active == true, nil, "input"),
          tostring(d.icon or "microphone"),
          score
        ))
      end
    end
  end

  -- Disband rows for existing groups.
  for _, d in ipairs(snap.outputs or {}) do
    if type(d) == "table" and d.group == true then
      local members = type(d.groupMembers) == "table" and table.concat(d.groupMembers, ", ") or ""
      local hay = tr("launcher.disband") .. " " .. tostring(d.name or "") .. " " .. members
      local score = scoreFor(hay, nil)
      if score ~= nil then
        table.insert(rows, deviceRow(
          "ungroup:" .. tostring(d.id),
          tr("launcher.disband"),
          tr("launcher.group_members", { members = members }),
          "stack-2",
          score
        ))
      end
    end
  end

  -- Connected Bluetooth devices: explicit reconnect row (disconnect + connect).
  local reconnected = {}
  for _, d in ipairs(snap.outputs or {}) do
    if type(d) == "table" and d.bluetooth == true and d.available == true
      and type(d.address) == "string" and d.address ~= "" and reconnected[d.address] ~= true then
      reconnected[d.address] = true
      local hay = "reconnect " .. tostring(d.name or "")
      local score = scoreFor(hay, nil)
      if score ~= nil then
        table.insert(rows, deviceRow(
          "recon:" .. d.address,
          tr("launcher.reconnect", { name = tostring(d.name or "") }),
          tr("launcher.reconnect_hint"),
          "refresh",
          score
        ))
      end
    end
  end

  -- Group selector rows: one per groupable output, always visible.
  local picked = 0
  for _, v in pairs(selectedIds) do
    if v then picked += 1 end
  end
  for _, d in ipairs(snap.outputs or {}) do
    if type(d) == "table" and d.hidden ~= true and usableForGroup(d) then
      local chosen = selectedIds[tostring(d.id)] == true
      local name = tostring(d.name or "")
      local hay = tr("launcher.group_add", { name = name }) .. " " .. name
      local score = scoreFor(hay, nil)
      if score ~= nil then
        table.insert(rows, deviceRow(
          "sel:" .. tostring(d.id),
          tr("launcher.group_add", { name = name }),
          chosen and tr("launcher.selected") or tr("launcher.group_add_hint"),
          chosen and "check" or "stack-2",
          score
        ))
      end
    end
  end

  if picked >= 2 then
    table.insert(rows, deviceRow(
      "do-group",
      tr("actions.create_group", { count = picked }),
      tr("launcher.create_group_hint"),
      "check",
      5
    ))
  end
  if picked > 0 then
    table.insert(rows, deviceRow(
      "clear-sel",
      tr("launcher.clear_sel"),
      tr("launcher.clear_sel_hint"),
      "x",
      scoreFor(tr("launcher.clear_sel"), nil) or 1
    ))
  end

  if #rows == 0 then
    launcher.setResults(query, {
      { id = "", title = tr("launcher.no_devices"), glyph = "search-off" },
      panelRow(2),
    })
    return
  end

  table.insert(rows, deviceRow(
    "open-panel",
    tr("launcher.open"),
    tr("launcher.description"),
    "switch-horizontal",
    scoreFor(tr("launcher.open") .. " " .. tr("launcher.description"), nil)
  ))

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

  -- Last service result as a feedback row (process start/finish is silent; only
  -- the result tells whether create_output_group actually went through).
  if lastResult ~= nil and noctalia.nowMs() - (lastResult.at or 0) < 8000 then
    table.insert(rows, 1, {
      id = "result-note",
      title = lastResult.message,
      glyph = lastResult.ok and "check" or "alert-triangle",
      score = 6,
    })
  end

  launcher.setResults(query, rows)
end

-- Feedback channel: keep the last result for the feedback row above. The result
-- table's message is already localized by the service.
noctalia.state.watch(RESULT_KEY, function(result)
  if type(result) == "table" and tostring(result.message or "") ~= "" then
    lastResult = { message = tostring(result.message), ok = result.ok == true, at = noctalia.nowMs() }
    if type(lastQuery) == "string" then
      onQuery(lastQuery)
    end
  end
end)

-- Repaint when the service publishes a new snapshot (new group, connected BT);
-- also fires while the window is closed, which is harmless.
noctalia.state.watch(SNAPSHOT_KEY, function()
  if type(lastQuery) == "string" then
    onQuery(lastQuery)
  end
end)

function onQuery(query)
  lastQuery = type(query) == "string" and query or ""
  local snap = noctalia.state.get(SNAPSHOT_KEY)
  if type(snap) ~= "table" or type(snap.outputs) ~= "table" then
    launcher.setResults(query, {
      { id = "open-panel", title = tr("launcher.open"), subtitle = tr("launcher.description"), glyph = "switch-horizontal", score = 0 },
    })
    return
  end

  if snap.loading == true then
    launcher.setResults(query, {
      { id = "", title = tr("launcher.loading"), glyph = "loader" },
      { id = "open-panel", title = tr("launcher.open"), subtitle = tr("launcher.description"), glyph = "switch-horizontal", score = 2 },
    })
    return
  end

  publish(lastQuery, snap, noctalia.string.trim(lastQuery))
end

function onActivate(id)
  if type(id) ~= "string" or id == "" then
    return
  end

  if id == "open-panel" then
    noctalia.togglePanel(PANEL_ID)
    return
  end

  if id == "result-note" then
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
      selectedIds = {}
    end
    return
  end

  if id == "clear-sel" then
    selectedIds = {}
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
