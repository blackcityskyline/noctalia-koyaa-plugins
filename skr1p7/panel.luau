--!nonstrict

local VIEW_GRID = "grid"
local VIEW_LIST = "list"
local VIEW_EDIT = "edit"
local VIEW_FORM = "form"
local VIEW_GLYPH = "glyph"
local VIEW_TOML = "toml"

local DRAG_TYPE = "skr1p7-script"

local SORT_MODES = { "usage", "new_to_old", "old_to_new", "alpha" }
local SORT_CONFIG = {
  usage      = { label = "sort.usage",      glyph = "flame" },
  new_to_old = { label = "sort.new_to_old", glyph = "arrow-down" },
  old_to_new = { label = "sort.old_to_new", glyph = "arrow-up" },
  alpha      = { label = "sort.alpha",       glyph = "sort-letters" },
}

local ALL_GESTURES = {
  "lmb", "rmb", "mmb", "scroll_up", "scroll_down", "scroll_left", "scroll_right", "enter",
}
local GESTURE_LABELS = {
  lmb = "gesture.lmb", rmb = "gesture.rmb", mmb = "gesture.mmb",
  scroll_up = "gesture.scroll_up", scroll_down = "gesture.scroll_down",
  scroll_left = "gesture.scroll_left", scroll_right = "gesture.scroll_right",
  enter = "gesture.enter",
}

local GLYPH_PATHS = {
  "/usr/share/noctalia/assets/fonts/tabler.json",
  "/usr/local/share/noctalia/assets/fonts/tabler.json",
}

local view = "grid"
local prevView = "grid"
local scripts = {}
local render

local formRev = 0
local hoveredTool = nil
local searchQuery = ""
local sortMode = "usage"
local usageCounts = {}
local lastStatus = nil
local statusTimer = 0

local draftGlyph = "terminal-2"
local draftName = ""
local draftLabel = ""
local draftDescription = ""
local draftTooltip = ""
local draftCommand = ""
local draftGestures = {}
local editingIndex = nil
local draftError = nil
local draftSudo = false

local GLYPH_CATALOG = {}
local glyphPage = 0
local addGestureKeys = {}
for _, path in ipairs(GLYPH_PATHS) do
  if noctalia.fileExists(path) then
    local raw = noctalia.readFile(path)
    if raw then
      local decoded = noctalia.json.decode(raw)
      if type(decoded) == "table" then
        if type(decoded[1]) == "table" then
          for _, item in ipairs(decoded) do
            if item.name then table.insert(GLYPH_CATALOG, item.name) end
          end
        else
          for name in pairs(decoded) do table.insert(GLYPH_CATALOG, tostring(name)) end
          table.sort(GLYPH_CATALOG)
        end
      end
    end
  end
end

local function tr(key, subst)
  return subst and noctalia.tr(key, subst) or noctalia.tr(key)
end

local function resolveDataPath()
  local c = noctalia.getConfig("data_path")
  if type(c) == "string" and noctalia.string.trim(c) ~= "" then
    return noctalia.expandPath(noctalia.string.trim(c)), nil
  end
  local d, e = noctalia.pluginDataDir()
  return d and (d .. "/scripts.json") or nil, d == nil and e or nil
end

local dataPath, _ = resolveDataPath()

local function loadScripts()
  if dataPath == nil then scripts = {}; return end
  if not noctalia.fileExists(dataPath) then scripts = {}; return end
  local raw = noctalia.readFile(dataPath)
  if raw == nil then scripts = {}; return end
  local decoded = noctalia.json.decode(raw)
  if type(decoded) == "table" then
    scripts = decoded
  else
    scripts = {}
  end
end

local function saveScripts()
  if dataPath == nil then return false, "no data dir" end
  local encoded, err = noctalia.json.encode(scripts)
  if encoded == nil then return false, tostring(err) end
  local ok, writeErr = noctalia.writeFile(dataPath, encoded)
  return ok or false, writeErr and tostring(writeErr) or nil
end

local function runScript(cmd, label, useSudo)
  if type(cmd) ~= "string" or cmd == "" then return end
  if useSudo then
    local esc = noctalia.getConfig("privilege_escalation") or "none"
    if esc ~= "none" then cmd = esc .. " " .. cmd end
  end
  noctalia.runAsync(cmd, function(result)
    if result.exitCode == 0 then
      lastStatus = { ok = true, label = label or "", time = os.time() }
    else
      lastStatus = { ok = false, label = label or "", time = os.time() }
    end
    statusTimer = 0
    render()
  end)
end

local function handleGesture(s, gestureKey)
  local cmd = (s.actions or {})[gestureKey] or s.cmd
  if cmd and type(cmd) == "string" and cmd ~= "" then
    runScript(cmd, s.name or s.label or "", s.sudo == true)
  end
end

local function getItemActions(s)
  return {
    lmb = (s.actions or {}).lmb or s.cmd or "",
    rmb = (s.actions or {}).rmb or "",
    mmb = (s.actions or {}).mmb or "",
  }
end

local function getActiveScripts()
  local q = searchQuery:lower()
  local items = {}
  for i, s in ipairs(scripts) do
    if q == "" then
      table.insert(items, { s = s, i = i })
    else
      local label = (s.name or s.label or ""):lower()
      if label:find(q, 1, true) then
        table.insert(items, { s = s, i = i })
      else
        local found = false
        for _, c in pairs(s.actions or {}) do
          if type(c) == "string" and c:lower():find(q, 1, true) then
            found = true; break
          end
        end
        if found or tostring(s.cmd or ""):lower():find(q, 1, true) then
          table.insert(items, { s = s, i = i })
        end
      end
    end
  end
  if sortMode == "new_to_old" then
    table.sort(items, function(a, b) return a.i > b.i end)
  elseif sortMode == "old_to_new" then
    table.sort(items, function(a, b) return a.i < b.i end)
  elseif sortMode == "alpha" then
    table.sort(items, function(a, b)
      return (a.s.name or a.s.label or ""):lower() < (b.s.name or b.s.label or ""):lower()
    end)
  elseif sortMode == "usage" then
    table.sort(items, function(a, b)
      local ua = usageCounts[tostring(a.i)] or 0
      local ub = usageCounts[tostring(b.i)] or 0
      return ua ~= ub and ua > ub or a.i < b.i
    end)
  end
  return items
end

local function scriptTile(s, i)
  local actions = getItemActions(s)
  local isHovered = hoveredTool == i

  local function setHover(state)
    if state == "true" then hoveredTool = i else hoveredTool = nil end
    render()
  end

  return ui.column({
    key = "tile-" .. i, flexGrow = 1, gap = 2, align = "center", paddingV = 6, radius = 8,
    onClick = function() handleGesture(s, "lmb") end,
    onRightClick = function() handleGesture(s, "rmb") end,
    onMiddleClick = function() handleGesture(s, "mmb") end,
    onHover = setHover,
  }, {
    ui.column({
      width = 37, height = 37, radius = 10,
      fill = isHovered and "hover" or "on_primary",
      border = "outline", borderWidth = 1,
      align = "center", justify = "center",
      onHover = setHover,
    }, {
      ui.glyph({ name = s.glyph or "terminal-2", size = 19, color = isHovered and "hover" or "primary" }),
    }),
    ui.column({ onHover = setHover, align = "center" }, {
      ui.label({ text = s.name or s.label or "", maxWidth = 80, maxLines = 1, textAlign = "center", fontSize = 12, color = isHovered and "hover" or "primary" }),
    }),
    isHovered and s.tooltip and s.tooltip ~= "" and
      ui.label({ text = s.tooltip, maxWidth = 100, maxLines = 2, textAlign = "center", fontSize = 10, color = "on_surface_variant" })
    or nil,
  })
end

local function statusWidget()
  if lastStatus == nil then return nil end
  if os.time() - lastStatus.time > 5 then lastStatus = nil; return nil end
  local icon = lastStatus.ok and "check" or "alert-triangle"
  local color = lastStatus.ok and "primary" or "error"
  local text = lastStatus.ok
    and (lastStatus.label .. " — " .. tr("status.ok", { label = "" }))
    or (lastStatus.label .. " — " .. tr("status.error", { label = "" }))
  return ui.row({ gap = 6, align = "center", paddingH = 6, paddingV = 4, radius = 6, fill = "surface_variant" }, {
    ui.glyph({ name = icon, size = 14, color = color }),
    ui.label({ text = text, fontSize = 11, color = color, flexGrow = 1 }),
  })
end

local function searchBar()
  return ui.input({
    key = "search-" .. formRev,
    value = searchQuery,
    placeholder = tr("panel.search_placeholder"),
    glyph = "search",
    flexGrow = 1,
    onChange = function(v) searchQuery = v end,
  })
end

local function sortButton()
  local cfg = SORT_CONFIG[sortMode] or SORT_CONFIG.usage
  return ui.button({
    key = "sort-btn",
    glyph = cfg.glyph,
    width = 24, height = 24,
    tooltip = tr(cfg.label),
    onClick = "_onToggleSort",
  })
end

local function gridView()
  local cols = tonumber(noctalia.getConfig("columns")) or 4
  local items = getActiveScripts()
  local gridContent

  if #items == 0 then
    gridContent = ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 6 }, {
      ui.glyph({ name = "terminal-2", size = 32, color = "on_surface_variant" }),
      ui.label({ text = tr("panel.empty"), color = "on_surface_variant", fontSize = 12 }),
      ui.button({ text = tr("panel.add"), glyph = "plus", variant = "primary", onClick = "_onNewScript" }),
    })
  else
    local rows = {}
    local currentRow = {}
    for _, item in ipairs(items) do
      table.insert(currentRow, scriptTile(item.s, item.i))
      if #currentRow >= cols then
        table.insert(rows, ui.row({ gap = 4, flexGrow = 1 }, currentRow))
        currentRow = {}
      end
    end
    if #currentRow > 0 then
      table.insert(rows, ui.row({ gap = 4, flexGrow = 1 }, currentRow))
    end
    gridContent = ui.scroll({ flexGrow = 1, gap = 6 }, { ui.column({ gap = 4 }, rows) })
  end

  return ui.column({ gap = 6, paddingH = 6, paddingV = 6, flexGrow = 1 }, {
    ui.row({ gap = 6, align = "center" }, {
      sortButton(),
      searchBar(),
      ui.button({ glyph = "pencil", width = 24, height = 24, tooltip = tr("panel.tip_edit"), onClick = "_onOpenEdit" }),
      ui.button({ glyph = "file-code", width = 24, height = 24, tooltip = tr("panel.tip_toml"), onClick = "_onOpenToml" }),
      ui.button({ glyph = "x", width = 24, height = 24, tooltip = tr("panel.tip_close"), onClick = function() panel.close() end }),
    }),
    gridContent,
    statusWidget(),
  })
end

local function listView()
  local items = getActiveScripts()
  local listContent

  if #items == 0 then
    listContent = ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 6 }, {
      ui.glyph({ name = "terminal-2", size = 32, color = "on_surface_variant" }),
      ui.label({ text = tr("panel.empty"), color = "on_surface_variant", fontSize = 12 }),
      ui.button({ text = tr("panel.add"), glyph = "plus", variant = "primary", onClick = "_onNewScript" }),
    })
  else
    local rows = {}
    for _, item in ipairs(items) do
      local s = item.s
      local actions = getItemActions(s)
      local isHovered = hoveredTool == item.i
      local rightText = isHovered and (s.description or "") or (s.label or "")

      local function setHover(state)
        if state == "true" then hoveredTool = item.i else hoveredTool = nil end
        render()
      end

      table.insert(rows, ui.row({
        key = "row-" .. item.i, gap = 8, align = "center", height = 34, paddingH = 4, radius = 6,
        onClick = function() handleGesture(s, "lmb") end,
        onRightClick = function() handleGesture(s, "rmb") end,
        onMiddleClick = function() handleGesture(s, "mmb") end,
        onHover = setHover,
      }, {
        ui.button({
          key = "tooltip-" .. item.i,
          glyph = s.glyph or "terminal-2", variant = "ghost",
          tooltip = s.tooltip or "",
          width = 28, height = 28,
          onClick = function() handleGesture(s, "lmb") end,
        }),
        ui.column({ flexGrow = 1, onHover = setHover }, {
          ui.label({ text = s.name or s.label or "", maxLines = 1, color = isHovered and "hover" or "primary" }),
        }),
        ui.column({ onHover = setHover }, {
          ui.label({ text = rightText, maxLines = 1, fontSize = 11, color = isHovered and "hover" or "on_surface_variant" }),
        }),
      }))
    end
    listContent = ui.scroll({ flexGrow = 1, gap = 2 }, rows)
  end

  return ui.column({ gap = 6, paddingH = 6, paddingV = 6, flexGrow = 1 }, {
    ui.row({ gap = 6, align = "center" }, {
      sortButton(),
      searchBar(),
      ui.button({ glyph = "pencil", width = 24, height = 24, tooltip = tr("panel.tip_edit"), onClick = "_onOpenEdit" }),
      ui.button({ glyph = "file-code", width = 24, height = 24, tooltip = tr("panel.tip_toml"), onClick = "_onOpenToml" }),
      ui.button({ glyph = "x", width = 24, height = 24, tooltip = tr("panel.tip_close"), onClick = function() panel.close() end }),
    }),
    listContent,
    statusWidget(),
  })
end

local function editScriptRow(s, i)
  return ui.row({ gap = 8, align = "center", height = 36, paddingH = 4, radius = 6 }, {
    ui.dragSource({
      key = "grip-" .. i,
      dragType = DRAG_TYPE,
      payload = tostring(i),
      previewAncestor = 1,
      liftFromLayout = true,
      width = 20, height = 20,
      align = "center", justify = "center",
    }, {
      ui.glyph({ name = "menu", size = 14, color = "on_surface_variant" }),
    }),
    ui.glyph({ name = s.glyph or "terminal-2", size = 16, color = s.sudo and "primary" or "on_surface" }),
    ui.label({ text = s.name or s.label or "", flexGrow = 1, maxLines = 1 }),
    ui.button({ glyph = "pencil", width = 24, height = 24, tooltip = tr("edit.edit"), onClick = function() _onEditScript(i) end }),
    ui.button({ glyph = "trash", width = 24, height = 24, tooltip = tr("edit.delete"), onClick = function() _onDeleteScript(i) end }),
  })
end

local function editView()
  local rows = {}
  for i, s in ipairs(scripts) do
    table.insert(rows, ui.dropZone({
      key = "drop-before-" .. i,
      accepts = { DRAG_TYPE },
      value = tostring(i),
      onDrop = "_onReorderScript",
      height = 3,
      radius = 4,
      expandOnDrag = true,
      hitSlop = 24,
    }))
    table.insert(rows, editScriptRow(s, i))
  end
  table.insert(rows, ui.dropZone({
    key = "drop-after-" .. #scripts,
    accepts = { DRAG_TYPE },
    value = tostring(#scripts + 1),
    onDrop = "_onReorderScript",
    height = 3,
    radius = 4,
    expandOnDrag = true,
    hitSlop = 24,
  }))

  return ui.column({ gap = 2, paddingH = 6, paddingV = 6, flexGrow = 1 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.button({ glyph = "chevron-left", width = 24, height = 24, tooltip = tr("panel.tip_back"), onClick = "_onBackToMain" }),
      ui.glyph({ name = "pencil", size = 16, color = "primary" }),
      ui.label({ text = tr("panel.edit_title"), flexGrow = 1, fontSize = 16, fontWeight = "bold" }),
      ui.button({ glyph = "plus", width = 24, height = 24, tooltip = tr("panel.tip_new"), onClick = "_onNewScript" }),
      ui.button({ glyph = "x", width = 24, height = 24, tooltip = tr("panel.tip_close"), onClick = "_onBackToMain" }),
    }),
    ui.scroll({ flexGrow = 1, gap = 0 }, rows),
  })
end

local function formView()
  local title = editingIndex and tr("panel.edit_script") or tr("panel.new_script")
  local hasError = draftError ~= nil

  local usedGestures = {}
  for _, g in ipairs(draftGestures) do usedGestures[g.gesture] = true end

  local gestureRows = {}
  for _, g in ipairs(draftGestures) do
    local lbl = GESTURE_LABELS[g.gesture] or g.gesture
    table.insert(gestureRows, ui.row({ gap = 4, align = "center" }, {
      ui.label({ text = tr(lbl), fontSize = 11, color = "on_surface", width = 80 }),
      ui.input({ key = "gest-" .. g.gesture .. "-" .. formRev, value = g.command or "", controlSize = "sm", flexGrow = 1, onChange = function(v) g.command = v end }),
      ui.button({ glyph = "trash", width = 20, height = 20, onClick = function()
        local newGestures = {}
        for _, gg in ipairs(draftGestures) do
          if gg.gesture ~= g.gesture then table.insert(newGestures, gg) end
        end
        draftGestures = newGestures
        formRev += 1
        render()
      end }),
    }))
  end

  local addGestureOptions = {}
  addGestureKeys = {}
  for _, key in ipairs(ALL_GESTURES) do
    if not usedGestures[key] then
      table.insert(addGestureOptions, tr(GESTURE_LABELS[key] or key))
      table.insert(addGestureKeys, key)
    end
  end

  local addGestureSelect = nil
  if #addGestureOptions > 0 then
    addGestureSelect = ui.select({
      key = "add-gesture-" .. formRev,
      options = addGestureOptions,
      selectedIndex = 0,
      placeholder = tr("form.add_gesture"),
      flexGrow = 1,
      onChange = "_onAddGesture",
    })
  end

  return ui.column({ flexGrow = 1, gap = 6, paddingH = 6, paddingV = 6 }, {
    ui.row({ gap = 6, align = "center" }, {
      ui.button({ glyph = "chevron-left", width = 24, height = 24, tooltip = tr("panel.tip_back"), onClick = "_onCancelForm" }),
      ui.glyph({ name = "terminal-2", size = 16, color = "primary" }),
      ui.label({ text = title, flexGrow = 1, fontSize = 16, fontWeight = "bold" }),
    }),
    ui.row({ gap = 6, align = "center" }, {
      ui.button({ glyph = draftGlyph, width = 36, height = 36, onClick = "_onOpenGlyph", tooltip = tr("form.pick_glyph") }),
      ui.label({ text = draftGlyph, color = "on_surface_variant", fontSize = 11 }),
    }),
    ui.input({ key = "name-" .. formRev, value = draftName, placeholder = tr("form.name"), focus = true, onChange = function(v) draftName = v end }),
    ui.input({ key = "label-" .. formRev, value = draftLabel, placeholder = tr("form.label"), onChange = function(v) draftLabel = v end }),
    ui.input({ key = "desc-" .. formRev, value = draftDescription, placeholder = tr("form.description"), onChange = function(v) draftDescription = v end }),
    ui.input({ key = "tooltip-" .. formRev, value = draftTooltip, placeholder = tr("form.tooltip"), onChange = function(v) draftTooltip = v end }),
    ui.input({ key = "cmd-" .. formRev, value = draftCommand, placeholder = tr("form.command"), onChange = function(v) draftCommand = v end }),
    hasError and ui.label({ text = draftError, color = "error", fontSize = 11 }) or nil,
    ui.label({ text = tr("form.actions_header"), fontSize = 12, fontWeight = "bold", color = "on_surface_variant" }),
    ui.column({ gap = 4 }, gestureRows),
    addGestureSelect,
    ui.row({ gap = 8 }, {
      ui.button({ text = tr("actions.cancel"), variant = "destructive", onClick = "_onCancelForm" }),
      ui.button({ text = tr("actions.save"), variant = "primary", onClick = "_onSaveScript" }),
    }),
  })
end

local function glyphView()
  local filtered = {}
  if searchQuery ~= "" then
    for _, g in ipairs(GLYPH_CATALOG) do
      if g:lower():find(searchQuery:lower(), 1, true) then
        table.insert(filtered, g)
      end
    end
  else
    filtered = GLYPH_CATALOG
  end

  if #filtered == 0 then
    return ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 6 }, {
      ui.label({ text = tr("form.no_glyphs"), color = "on_surface_variant", fontSize = 12 }),
    })
  end

  local PAGE_SIZE = 200
  local totalPages = math.ceil(#filtered / PAGE_SIZE)
  if glyphPage >= totalPages then glyphPage = totalPages - 1 end
  if glyphPage < 0 then glyphPage = 0 end
  local offset = glyphPage * PAGE_SIZE
  local showCount = math.min(PAGE_SIZE, #filtered - offset)

  local cols = 8
  local rows = {}
  local row = {}
  for i = 1, showCount do
    local g = filtered[offset + i]
    table.insert(row, ui.button({
      key = "glyph-" .. offset + i, glyph = g,
      flexGrow = 1, width = 0,
      variant = g == draftGlyph and "primary" or "ghost",
      onClick = function() draftGlyph = g; searchQuery = ""; glyphPage = 0; render() end,
    }))
    if #row >= cols then
      table.insert(rows, ui.row({ gap = 2, flexGrow = 1 }, row))
      row = {}
    end
  end
  if #row > 0 then table.insert(rows, ui.row({ gap = 2, flexGrow = 1 }, row)) end

  local navRow = nil
  if totalPages > 1 then
    navRow = ui.row({ gap = 8, align = "center" }, {
      ui.button({ glyph = "chevron-left", width = 24, height = 24, variant = "ghost", tooltip = tr("panel.tip_prev"),
        onClick = function() if glyphPage > 0 then glyphPage = glyphPage - 1; render() end end,
      }),
      ui.label({ text = (glyphPage + 1) .. " / " .. totalPages, fontSize = 11, color = "on_surface_variant" }),
      ui.button({ glyph = "chevron-right", width = 24, height = 24, variant = "ghost", tooltip = tr("panel.tip_next"),
        onClick = function() if glyphPage < totalPages - 1 then glyphPage = glyphPage + 1; render() end end,
      }),
    })
  end

  return ui.column({ flexGrow = 1, gap = 6, paddingH = 6, paddingV = 6 }, {
    ui.row({ gap = 6, align = "center" }, {
      ui.button({ glyph = "chevron-left", width = 24, height = 24, tooltip = tr("panel.tip_back"), onClick = function() view = VIEW_FORM; searchQuery = ""; glyphPage = 0; render() end }),
      ui.glyph({ name = "palette", size = 16, color = "primary" }),
      ui.label({ text = tr("form.pick_glyph"), flexGrow = 1, fontSize = 15, fontWeight = "bold" }),
    }),
    ui.input({ key = "glyph-search-" .. formRev, value = searchQuery, placeholder = tr("form.glyph_search"), onChange = function(v) searchQuery = v; glyphPage = 0; render() end }),
    ui.scroll({ flexGrow = 1, gap = 2 }, rows),
    navRow,
  })
end

local function tomlView()
  local raw = noctalia.json.encode(scripts, true)
  return ui.column({ flexGrow = 1, gap = 6, paddingH = 6, paddingV = 6 }, {
    ui.row({ gap = 6, align = "center" }, {
      ui.button({ glyph = "chevron-left", width = 24, height = 24, tooltip = tr("panel.tip_back"), onClick = "_onBackToMain" }),
      ui.glyph({ name = "file-code", size = 16, color = "primary" }),
      ui.label({ text = "Configuration", flexGrow = 1, fontSize = 16, fontWeight = "bold" }),
      ui.button({ glyph = "clipboard", width = 24, height = 24, tooltip = tr("panel.tip_import"), onClick = "_onImportConfig" }),
      ui.button({ glyph = "copy", width = 24, height = 24, tooltip = tr("panel.tip_export"), onClick = "_onExportConfig" }),
      ui.button({ text = tr("actions.save"), variant = "primary", width = 24, height = 24, tooltip = tr("panel.tip_save"), onClick = "_onSaveToml" }),
    }),
    ui.input({
      key = "toml-editor-" .. formRev,
      value = raw or "[]",
      multiline = true,
      flexGrow = 1,
      placeholder = "JSON",
      onChange = function(v) draftCommand = v end,
    }),
  })
end

render = function()
  if view == VIEW_FORM then panel.render(formView())
  elseif view == VIEW_GLYPH then panel.render(glyphView())
  elseif view == VIEW_TOML then panel.render(tomlView())
  elseif view == VIEW_LIST then panel.render(listView())
  elseif view == VIEW_EDIT then panel.render(editView())
  else panel.render(gridView()) end
end

function _onToggleSort()
  local idx = 1
  for i, mode in ipairs(SORT_MODES) do
    if mode == sortMode then idx = i; break end
  end
  sortMode = SORT_MODES[(idx % #SORT_MODES) + 1]
  render()
end

function _onOpenEdit()
  prevView = view
  view = VIEW_EDIT
  render()
end

function _onOpenToml()
  prevView = view
  formRev += 1
  draftCommand = noctalia.json.encode(scripts) or "[]"
  view = VIEW_TOML
  render()
end

function _onSaveToml()
  local decoded = noctalia.json.decode(draftCommand)
  if type(decoded) == "table" then
    scripts = decoded
    local ok, err = saveScripts()
    if ok then
      view = prevView or VIEW_GRID
      render()
    else
      draftError = tostring(err)
      render()
    end
  else
    draftError = "Invalid JSON"
    render()
  end
end

function _onExportConfig()
  local raw = noctalia.json.encode(scripts, true) or "[]"
  noctalia.copyToClipboard(raw, "text/plain")
end

function _onImportConfig()
  local clip = noctalia.clipboardText()
  if clip == nil or clip == "" then return end
  local decoded = noctalia.json.decode(clip)
  if type(decoded) == "table" then
    scripts = decoded
    draftCommand = noctalia.json.encode(scripts, true) or "[]"
    formRev += 1
    render()
  else
    draftError = "Invalid JSON in clipboard"
    render()
  end
end

function _onBackToMain()
  view = prevView or VIEW_GRID
  render()
end

function _onNewScript()
  editingIndex = nil
  draftGlyph = "terminal-2"
  draftName = ""
  draftLabel = ""
  draftDescription = ""
  draftTooltip = ""
  draftCommand = ""
  draftGestures = { { gesture = "lmb", command = "" } }
  draftSudo = false
  draftError = nil
  formRev += 1
  view = VIEW_FORM
  render()
end

function _onEditScript(index)
  local s = scripts[tonumber(index)]
  if s == nil then return end
  editingIndex = index
  draftGlyph = s.glyph or "terminal-2"
  draftName = s.name or s.label or ""
  draftLabel = s.label or ""
  draftDescription = s.description or ""
  draftTooltip = s.tooltip or ""
  draftCommand = s.cmd or ""
  draftGestures = {}
  if type(s.actions) == "table" then
    for _, key in ipairs(ALL_GESTURES) do
      local cmd = s.actions[key] or ""
      if cmd ~= "" then
        table.insert(draftGestures, { gesture = key, command = cmd })
      end
    end
  end
  if #draftGestures == 0 then
    draftGestures = { { gesture = "lmb", command = s.cmd or "" } }
  end
  draftSudo = s.sudo == true
  draftError = nil
  formRev += 1
  view = VIEW_FORM
  render()
end

function _onOpenGlyph()
  prevView = view
  searchQuery = ""
  formRev += 1
  view = VIEW_GLYPH
  render()
end

function _onAddGesture(selectedIndex)
  local idx = (tonumber(selectedIndex) or 0) + 1
  local key = addGestureKeys[idx]
  if key then
    table.insert(draftGestures, { gesture = key, command = "" })
    formRev += 1
    render()
  end
end

function _onCancelForm()
  if editingIndex then
    view = VIEW_EDIT
  else
    view = prevView or VIEW_GRID
  end
  render()
end

function _onSaveScript()
  local name = noctalia.string.trim(draftName)
  if name == "" then
    draftError = "Name is required"
    render()
    return
  end

  local label = noctalia.string.trim(draftLabel)
  if label == "" then label = name end

  local glyph = noctalia.string.trim(draftGlyph)
  if glyph == "" then glyph = "terminal-2" end

  local actions = {}
  for _, g in ipairs(draftGestures) do
    if g.command and g.command ~= "" then
      actions[g.gesture] = g.command
    end
  end

  local entry = {
    name = name, label = label, glyph = glyph,
    cmd = actions.lmb or "",
    description = draftDescription, tooltip = draftTooltip,
    actions = actions, sudo = draftSudo,
  }
  local prev = nil

  if editingIndex then
    prev = scripts[tonumber(editingIndex)]
    scripts[tonumber(editingIndex)] = entry
  else
    table.insert(scripts, entry)
  end

  local ok, err = saveScripts()
  if not ok then
    if editingIndex and prev then
      scripts[tonumber(editingIndex)] = prev
    else
      table.remove(scripts)
    end
    draftError = tostring(err)
    render()
    return
  end

  if editingIndex then
    view = VIEW_EDIT
  else
    view = prevView or VIEW_GRID
  end
  render()
end

function _onDeleteScript(index)
  local idx = tonumber(index)
  local s = scripts[idx]
  if s == nil then return end
  local removed = table.remove(scripts, idx)
  local ok, err = saveScripts()
  if not ok then
    table.insert(scripts, idx, removed)
    noctalia.notifyError(tr("title"), "Delete failed: " .. tostring(err))
  end
  render()
end

function _onReorderScript(payload, value)
  local fromIndex = tonumber(payload)
  local toIndex = tonumber(value)
  if fromIndex == nil or toIndex == nil then return end
  if fromIndex == toIndex or fromIndex == toIndex - 1 then return end

  local item = table.remove(scripts, fromIndex)
  if toIndex > fromIndex then toIndex -= 1 end
  table.insert(scripts, toIndex, item)

  local ok, err = saveScripts()
  if not ok then
    local reinsert = table.remove(scripts, toIndex)
    table.insert(scripts, fromIndex, reinsert)
    noctalia.notifyError(tr("title"), "Reorder failed: " .. tostring(err))
  end
  render()
end

function onOpen(_context)
  local mode = noctalia.getConfig("view_mode")
  if mode == "list" then
    prevView = VIEW_LIST
    view = VIEW_LIST
  else
    prevView = VIEW_GRID
    view = VIEW_GRID
  end
  searchQuery = ""
  hoveredTool = nil
  loadScripts()
  render()
end

function onClose()
  lastStatus = nil
end

function update()
  noctalia.setUpdateInterval(5000)
  if lastStatus and os.time() - lastStatus.time > 5 then
    lastStatus = nil
    render()
  end
end
