--!nonstrict

-- ═══════════════════════════════════════════════════════════
-- CONSTANTS
-- ═══════════════════════════════════════════════════════════

local SNAPSHOT_KEY = "audio_switcher_snapshot"
local COMMAND_KEY = "audio_switcher_command"
local RESULT_KEY = "audio_switcher_result"

local ICON_STYLES = { "automatic", "speaker", "over_ear", "tws", "wired" }

-- ═══════════════════════════════════════════════════════════
-- STATE
-- ═══════════════════════════════════════════════════════════

local snapshot = noctalia.state.get(SNAPSHOT_KEY) or {
  available = false, bluetoothAvailable = false, loading = true,
  busy = false, scanning = false, outputs = {}, inputs = {},
  defaultOutputId = "", defaultInputId = "",
  outputVolume = 0, inputVolume = 0,
  outputMuted = false, inputMuted = false, error = "", updatedAt = 0,
}

local tab = "output"
local showHidden = false
local grouping = false
local selectedGroup = {}
local editing = { id = nil, alias = "", iconStyle = "automatic", slot = "" }
local feedback = { text = "", isError = false }
local requestCounter = 0
local volumeCommit = { output = nil, input = nil }
local volumeRev = 0
local render

-- ═══════════════════════════════════════════════════════════
-- HELPERS
-- ═══════════════════════════════════════════════════════════

local function tr(key, subs) return noctalia.tr(key, subs) end
local function asArray(v) return type(v) == "table" and v or {} end

local function nextRequestId()
  requestCounter += 1
  return "panel-" .. tostring(requestCounter)
end

local function sendCommand(action, values)
  local cmd = { action = action, requestId = nextRequestId() }
  if type(values) == "table" then for k, v in pairs(values) do cmd[k] = v end end
  noctalia.state.set(COMMAND_KEY, cmd)
  return cmd.requestId
end

local function devices(kind)
  return kind == "output" and asArray(snapshot.outputs) or asArray(snapshot.inputs)
end

local function activeDevice(kind)
  for _, d in ipairs(devices(kind)) do
    if d.active then return d end
  end
  return nil
end

local function inputDisplayName(device)
  if device == nil then return "" end
  local port = noctalia.string.trim(tostring(device.activePortDescription or ""))
  return port ~= "" and port or tostring(device.name or "")
end

local function deviceCount(kind, hidden)
  local count = 0
  for _, d in ipairs(devices(kind)) do
    if (d.hidden == true) == hidden then count += 1 end
  end
  return count
end

local function groupSelectedCount()
  local count = 0
  for _, v in pairs(selectedGroup) do if v then count += 1 end end
  return count
end

local function selectIndex(values, selected)
  for i, v in ipairs(values) do
    if v == selected then return i - 1 end
  end
  return 0
end

local function resetTabState()
  editing.id = nil
  showHidden = false
  grouping = false
  selectedGroup = {}
  feedback.text = ""
  feedback.isError = false
end

-- ═══════════════════════════════════════════════════════════
-- UI COMPONENTS
-- ═══════════════════════════════════════════════════════════

local function volumeCard(kind)
  local isOut = kind == "output"
  local device = activeDevice(kind)
  local volume = tonumber(isOut and snapshot.outputVolume or snapshot.inputVolume) or 0
  local muted = isOut and snapshot.outputMuted == true or not isOut and snapshot.inputMuted == true
  local icon = isOut and (muted and "volume-off" or "volume") or (muted and "microphone-mute" or "microphone")

  return ui.column({ flexGrow = 1, gap = 8, padding = 12, radius = 12, fill = "surface_variant/0.45" }, {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = isOut and "volume" or "microphone", size = 18, color = isOut and "primary" or "tertiary" }),
      ui.column({ flexGrow = 1, gap = 2 }, {
        ui.label({ text = tr(isOut and "panel.output_volume" or "panel.input_volume"), fontWeight = "bold" }),
        ui.label({
          text = device and (isOut and device.name or inputDisplayName(device)) or tr("panel.no_device"),
          fontSize = 11, color = "on_surface_variant", maxLines = 1,
        }),
      }),
      ui.row({ align = "center", gap = 8 }, {
        ui.label({ text = tostring(volume) .. "%", fontSize = 11, color = "on_surface_variant" }),
        ui.button({
          glyph = icon, variant = muted and "destructive" or "ghost", controlSize = "sm",
          tooltip = tr(muted and "panel.unmute" or "panel.mute"), enabled = device ~= nil,
          onClick = isOut and "onToggleOutputMute" or "onToggleInputMute",
        }),
      }),
    }),
    ui.slider({
      key = "volume-" .. kind .. "-" .. tostring(volumeRev),
      min = 0, max = 100, step = 1, value = volume, enabled = device ~= nil,
      onChange = isOut and "onOutputVolumeChange" or "onInputVolumeChange",
      onDragEnd = isOut and "onOutputVolumeCommit" or "onInputVolumeCommit",
    }),
  })
end

local function deviceStatus(d)
  if d.active then return tr("device.active") end
  if d.bluetooth and not d.available then return tr("device.bluetooth_disconnected") end
  if d.bluetooth then return tr("device.bluetooth_connected") end
  return tr("device.available")
end

local function deviceSubtitle(d)
  local status = deviceStatus(d)
  local desc = noctalia.string.trim(tostring(d.description or ""))
  local port = noctalia.string.trim(tostring(d.activePortDescription or ""))
  if port ~= "" and port ~= d.name and port ~= desc then status = status .. "  ·  " .. port end
  if desc == "" or desc == "(null)" or desc:lower() == "null" then return status end
  if desc == d.name or desc == port then return status end
  return status .. "  ·  " .. desc
end

local function editor(d, kind)
  local children = {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "edit", size = 16, color = "primary" }),
      ui.label({ text = tr("editor.title"), fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "close", variant = "ghost", controlSize = "sm", onClick = "onCancelEdit" }),
    }),
    ui.label({ text = tr("editor.alias"), fontSize = 11, color = "on_surface_variant" }),
    ui.input({ key = "alias-" .. tostring(d.id), value = editing.alias, placeholder = d.description, onChange = "onEditAliasChange" }),
    ui.label({ text = tr("editor.icon"), fontSize = 11, color = "on_surface_variant" }),
    ui.select({
      options = { tr("editor.icon_options.automatic"), tr("editor.icon_options.speaker"), tr("editor.icon_options.over_ear"), tr("editor.icon_options.tws"), tr("editor.icon_options.wired") },
      selectedIndex = selectIndex(ICON_STYLES, editing.iconStyle), width = 220, onChange = "onEditIconChange",
    }),
  }
  if d.bluetooth then
    table.insert(children, ui.label({ text = tr("editor.slot"), fontSize = 11, color = "on_surface_variant" }))
    table.insert(children, ui.input({ key = "slot-" .. tostring(d.id), value = editing.slot, placeholder = "1", onChange = "onEditSlotChange" }))
    table.insert(children, ui.label({ text = tr("editor.slot_hint"), fontSize = 10, color = "on_surface_variant", maxLines = 2 }))
  end
  if kind == "output" then
    table.insert(children, ui.row({ gap = 8 }, {
      ui.button({ glyph = "player-play", text = tr("panel.test_sound"), variant = "ghost", controlSize = "sm", onClick = "onTestSound" }),
    }))
  end
  table.insert(children, ui.row({ justify = "end", gap = 8 }, {
    ui.button({ text = tr("actions.cancel"), variant = "ghost", onClick = "onCancelEdit" }),
    ui.button({ text = tr("actions.save"), glyph = "device-floppy", variant = "primary", onClick = "onSaveEdit" }),
  }))
  return ui.column({ gap = 7, padding = 10, radius = 9, fill = "surface_variant/0.45", border = "primary/0.35", borderWidth = 1 }, children)
end

local function deviceRow(d, kind)
  local useAction = function() sendCommand(kind == "output" and "set_output" or "set_input", { id = d.id }) end
  local editAction = function()
    editing.id = d.id
    editing.alias = tostring(d.name or "")
    editing.iconStyle = tostring(d.iconStyle or "automatic")
    editing.slot = d.slot and tostring(d.slot) or ""
    feedback.text = ""
    render()
  end
  local hideAction = function() sendCommand("set_hidden", { id = d.id, kind = kind, hidden = not d.hidden }) end
  local selectAction = function() selectedGroup[d.id] = not selectedGroup[d.id]; render() end
  local disbandAction = function() sendCommand("remove_output_group", { id = d.id }) end

  local ports = kind == "input" and asArray(d.ports) or {}
  local portOptions = {}
  local selectedPortIndex = 0
  for index, port in ipairs(ports) do
    local label = tostring(port.description or port.name or "")
    if port.available == false then label = tr("device.unavailable_port", { port = label }) end
    portOptions[#portOptions + 1] = label
    if port.active then selectedPortIndex = index - 1 end
  end
  local selectPortAction = function(index, _label)
    local port = ports[math.floor(tonumber(index) or -1) + 1]
    if port ~= nil and not port.active then sendCommand("set_input_port", { id = d.id, port = port.name }) end
  end

  local actionText = d.active and tr("device.current")
    or (d.bluetooth and not d.available and tr("actions.connect_and_use") or tr("actions.use"))
  local actionVariant = d.active and "ghost" or "primary"
  local statusColor = d.active and "secondary" or "on_surface_variant"

  local actions = {}
  if grouping and kind == "output" then
    table.insert(actions, ui.button({
      text = selectedGroup[d.id] and tr("actions.selected") or tr("actions.select"),
      glyph = selectedGroup[d.id] and "check" or "plus",
      variant = selectedGroup[d.id] and "primary" or "outline",
      controlSize = "sm",
      enabled = d.available == true and d.group ~= true and snapshot.busy ~= true,
      onClick = selectAction,
    }))
  else
    if d.active and d.bluetooth then
      table.insert(actions, ui.button({
        text = tr("actions.reconnect"), variant = "primary", controlSize = "sm",
        enabled = snapshot.busy ~= true,
        onClick = function() sendCommand("reconnect_bluetooth", { address = d.address }) end,
      }))
    elseif d.active then
      table.insert(actions, ui.button({
        text = tr("actions.reconnect"), variant = "primary", controlSize = "sm",
        enabled = snapshot.busy ~= true, onClick = useAction,
      }))
    else
      table.insert(actions, ui.button({
        text = actionText, variant = actionVariant, controlSize = "sm",
        enabled = not d.active and snapshot.busy ~= true, onClick = useAction,
      }))
    end
    if kind == "output" and d.group then
      table.insert(actions, ui.button({
        text = tr("actions.disband"), glyph = "unlink", variant = "outline", controlSize = "sm",
        enabled = snapshot.busy ~= true, onClick = disbandAction,
      }))
    else
      table.insert(actions, ui.button({ glyph = "edit", variant = "ghost", controlSize = "sm", tooltip = tr("actions.edit"), onClick = editAction }))
      table.insert(actions, ui.button({
        glyph = d.hidden and "eye" or "eye-off", variant = "ghost", controlSize = "sm",
        tooltip = tr(d.hidden and "actions.show" or "actions.hide"), onClick = hideAction,
      }))
    end
  end

  local rowChildren = {
    ui.glyph({ name = d.icon or (kind == "output" and "volume" or "microphone"), size = 19, color = d.active and "primary" or "on_surface_variant" }),
    ui.column({ flexGrow = 1, gap = 2 }, {
      ui.label({ text = tostring(d.name or d.description or d.id), fontWeight = "bold", maxLines = 1 }),
      ui.label({ text = deviceSubtitle(d), fontSize = 10, color = statusColor, maxLines = 1 }),
    }),
    ui.label({ text = d.slot and ("#" .. tostring(d.slot)) or "", color = "primary", fontSize = 11, fontWeight = "bold", visible = d.bluetooth == true }),
  }
  for _, action in ipairs(actions) do table.insert(rowChildren, action) end

  local rowElement = ui.row({
    align = "center", gap = 8, padding = 7, radius = 9,
    border = selectedGroup[d.id] and "primary" or (d.active and "primary" or "outline/0.55"),
    borderWidth = 1,
    fill = selectedGroup[d.id] and "primary/0.1" or (d.active and "primary/0.07" or "surface/0"),
  }, rowChildren)

  local hasPorts = kind == "input" and #ports > 1
  local hasEditor = editing.id == d.id
  if hasPorts or hasEditor then
    local extras = {}
    if hasPorts then
      table.insert(extras, ui.row({ gap = 8, align = "center", paddingH = 8 }, {
        ui.label({ text = tr("device.port"), color = "on_surface_variant", fontSize = 10 }),
        ui.select({ options = portOptions, selectedIndex = selectedPortIndex, flexGrow = 1, enabled = snapshot.busy ~= true, onChange = selectPortAction }),
      }))
    end
    if hasEditor then table.insert(extras, editor(d, kind)) end
    return ui.column({ gap = 6 }, { rowElement, table.unpack(extras) })
  end
  return rowElement
end

local function deviceList(kind)
  local rows = {}
  for _, d in ipairs(devices(kind)) do
    if showHidden or not d.hidden then
      table.insert(rows, deviceRow(d, kind))
    end
  end
  if #rows == 0 then
    table.insert(rows, ui.column({ align = "center", justify = "center", gap = 8, padding = 24 }, {
      ui.glyph({ name = kind == "output" and "volume-off" or "microphone-off", size = 32, color = "on_surface_variant" }),
      ui.label({ text = tr(showHidden and "panel.no_devices" or "panel.no_visible_devices"), color = "on_surface_variant", textAlign = "center" }),
    }))
  end
  return ui.column({ gap = 6 }, rows)
end

local function header()
  local output = activeDevice("output")
  local input = activeDevice("input")
  local subtitle = (output and output.name or tr("panel.no_output")) .. "  ·  "
    .. (input and inputDisplayName(input) or tr("panel.no_input"))
  return ui.row({ align = "center", gap = 8 }, {
    ui.glyph({ name = "switch-horizontal", size = 24, color = "primary" }),
    ui.column({ flexGrow = 1, gap = 2 }, {
      ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold" }),
      ui.label({ text = subtitle, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.button({
      glyph = "bluetooth",
      variant = snapshot.scanning and "primary" or "ghost",
      tooltip = tr(snapshot.scanning and "panel.scanning" or "panel.scan_bluetooth"),
      enabled = snapshot.bluetoothAvailable == true and snapshot.scanning ~= true,
      onClick = "onScanBluetooth",
    }),
    ui.button({ glyph = "refresh", variant = "ghost", tooltip = tr("actions.refresh"), onClick = "onRefresh" }),
    ui.button({ glyph = "settings", variant = "ghost", tooltip = tr("actions.settings"), onClick = "onOpenSettingsClicked" }),
    ui.button({ glyph = "close", variant = "ghost", tooltip = tr("actions.close"), onClick = "onCloseClicked" }),
  })
end

local function toolbar()
  local hidden = deviceCount(tab, true)
  local items = {
    ui.button({
      text = tr("tabs.outputs"), glyph = "volume",
      variant = tab == "output" and "primary" or "ghost",
      selected = tab == "output", onClick = "onShowOutputs",
    }),
    ui.button({
      text = tr("tabs.inputs"), glyph = "microphone",
      variant = tab == "input" and "primary" or "ghost",
      selected = tab == "input", onClick = "onShowInputs",
    }),
    ui.spacer({ flexGrow = 1 }),
    ui.label({ text = tr("panel.visible_count", { count = deviceCount(tab, false) }), fontSize = 10, color = "on_surface_variant" }),
    ui.button({
      text = hidden > 0 and tr("panel.hidden_count", { count = hidden }) or tr("panel.hidden"),
      glyph = showHidden and "eye" or "eye-off",
      variant = showHidden and "primary" or "ghost",
      selected = showHidden, enabled = hidden > 0 or showHidden,
      onClick = "onToggleHidden",
    }),
  }
  if tab == "output" then
    table.insert(items, ui.button({
      text = tr("actions.group"), glyph = "link",
      variant = grouping and "primary" or "outline",
      enabled = snapshot.busy ~= true, onClick = "onStartGrouping",
    }))
  end
  table.insert(items, ui.button({
    text = tr("actions.cycle"), glyph = "refresh", variant = "outline",
    enabled = snapshot.busy ~= true,
    onClick = tab == "output" and "onCycleOutput" or "onCycleInput",
  }))
  return ui.row({ align = "center", gap = 4 }, items)
end

-- ═══════════════════════════════════════════════════════════
-- RENDER
-- ═══════════════════════════════════════════════════════════

render = function()
  local statusRows = {}
  if snapshot.loading then
    table.insert(statusRows, ui.label({ text = tr("panel.loading"), color = "primary" }))
  end
  if snapshot.busy then
    table.insert(statusRows, ui.label({ text = tr("panel.switching"), color = "primary" }))
  end
  if tostring(snapshot.error or "") ~= "" then
    table.insert(statusRows, ui.label({ text = snapshot.error, color = "error", maxLines = 2 }))
  end
  if feedback.text ~= "" then
    table.insert(statusRows, ui.label({ text = feedback.text, color = feedback.isError and "error" or "secondary", maxLines = 2 }))
  end

  local children = {
    header(),
    ui.row({ gap = 12, align = "stretch" }, { volumeCard("output"), volumeCard("input") }),
    toolbar(),
    ui.column({ gap = 3 }, statusRows),
    ui.scroll({ flexGrow = 1 }, { deviceList(tab) }),
    ui.label({ text = tr("panel.keybind_hint"), fontSize = 10, color = "on_surface_variant", maxLines = 2 }),
  }

  if grouping and tab == "output" then
    local count = groupSelectedCount()
    table.insert(children, 4, ui.row({ align = "center", gap = 8, padding = 8, radius = 9, fill = "primary/0.08" }, {
      ui.label({ text = tr("panel.group_hint", { count = count }), flexGrow = 1, color = "on_surface_variant", fontSize = 11 }),
      ui.button({ text = tr("actions.cancel"), variant = "ghost", onClick = "onCancelGrouping" }),
      ui.button({
        text = tr("actions.create_group", { count = count }), glyph = "link", variant = "primary",
        enabled = count >= 2 and snapshot.busy ~= true, onClick = "onCreateGroup",
      }),
    }))
  end

  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, children))
end

-- ═══════════════════════════════════════════════════════════
-- EVENT HANDLERS
-- ═══════════════════════════════════════════════════════════

function onOpen(_context)
  feedback.text = ""
  feedback.isError = false
  grouping = false
  selectedGroup = {}
  sendCommand("refresh")
  render()
end

function onConfigChanged() render() end
function onCloseClicked() panel.close() end
function onRefresh() sendCommand("refresh") end
function onScanBluetooth() sendCommand("scan_bluetooth") end
function onCycleOutput() sendCommand("cycle_output") end
function onCycleInput() sendCommand("cycle_input") end
function onOpenSettingsClicked() noctalia.openSettings() end

function onShowOutputs()
  tab = "output"
  resetTabState()
  render()
end

function onShowInputs()
  tab = "input"
  resetTabState()
  render()
end

function onStartGrouping()
  grouping = true
  selectedGroup = {}
  editing.id = nil
  showHidden = false
  feedback.text = ""
  render()
end

function onCancelGrouping()
  grouping = false
  selectedGroup = {}
  render()
end

function onCreateGroup()
  local ids = {}
  for _, d in ipairs(devices("output")) do
    if selectedGroup[d.id] then table.insert(ids, d.id) end
  end
  if #ids < 2 then return end
  sendCommand("create_output_group", { ids = ids })
end

function onToggleHidden()
  showHidden = not showHidden
  editing.id = nil
  render()
end

function onCancelEdit()
  editing.id = nil
  render()
end

function onEditAliasChange(value) editing.alias = tostring(value or "") end
function onEditIconChange(index, _label)
  editing.iconStyle = ICON_STYLES[(math.floor(tonumber(index) or 0)) + 1] or "automatic"
end
function onEditSlotChange(value) editing.slot = tostring(value or "") end

function onSaveEdit()
  for _, d in ipairs(devices(tab)) do
    if d.id == editing.id then
      sendCommand("update_device", {
        id = d.id, address = d.address,
        alias = editing.alias, iconStyle = editing.iconStyle, slot = editing.slot,
      })
      editing.id = nil
      render()
      return
    end
  end
end

function onOutputVolumeChange(value)
  volumeCommit.output = math.floor(tonumber(value) or 0)
end

function onInputVolumeChange(value)
  volumeCommit.input = math.floor(tonumber(value) or 0)
end

function onOutputVolumeCommit()
  local value = volumeCommit.output or snapshot.outputVolume
  volumeCommit.output = nil
  sendCommand("set_output_volume", { value = value })
end

function onInputVolumeCommit()
  local value = volumeCommit.input or snapshot.inputVolume
  volumeCommit.input = nil
  sendCommand("set_input_volume", { value = value })
end

function onToggleOutputMute() sendCommand("toggle_output_mute") end
function onToggleInputMute() sendCommand("toggle_input_mute") end

function onTestSound()
  local path = noctalia.pluginDir() .. "/test-sound.wav"
  noctalia.runAsync("pw-play " .. path)
end

-- ═══════════════════════════════════════════════════════════
-- STATE WATCHERS
-- ═══════════════════════════════════════════════════════════

noctalia.state.watch(SNAPSHOT_KEY, function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

noctalia.state.watch(RESULT_KEY, function(result)
  if type(result) ~= "table" or not tostring(result.requestId or ""):match("^panel%-") then return end
  feedback.text = tostring(result.message or "")
  feedback.isError = result.ok ~= true
  if result.ok == true and result.action == "create_output_group" then
    grouping = false
    selectedGroup = {}
  end
  if result.ok ~= true and (result.action == "set_output_volume" or result.action == "set_input_volume") then
    volumeCommit.output = nil
    volumeCommit.input = nil
    volumeRev += 1
  end
  render()
end)

render()
