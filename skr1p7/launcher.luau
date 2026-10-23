--!nonstrict
-- /scr: run Script Box scripts from the launcher. Rows come from the same
-- scripts.json the panel reads; activating runs the command exactly like the
-- panel tile click (lmb action or cmd), including sudo escalation.

local PANEL_ID = "noctalia/skr1p7:panel"
local RESULT_LIMIT = 60
local CACHE_TTL_MS = 3000

local cache = { at = 0, scripts = nil }

local function resolveDataPath()
  local c = noctalia.getConfig("data_path")
  if type(c) == "string" and noctalia.string.trim(c) ~= "" then
    return noctalia.expandPath(noctalia.string.trim(c))
  end
  local d = noctalia.pluginDataDir()
  return d ~= nil and (d .. "/scripts.json") or nil
end

local function loadScripts()
  local path = resolveDataPath()
  if path == nil or not noctalia.fileExists(path) then
    return {}
  end
  local raw = noctalia.readFile(path)
  if raw == nil then
    return {}
  end
  local decoded = noctalia.json.decode(raw)
  if type(decoded) ~= "table" then
    return {}
  end
  return decoded
end

local function title(s)
  return s.name ~= nil and s.name ~= "" and s.name or (s.label or "")
end

-- Mirrors the panel's runScript: privileges come from the plugin setting.
local function run(s)
  if type(s) ~= "table" then
    return
  end
  local cmd = (s.actions or {}).lmb or s.cmd
  if type(cmd) ~= "string" or cmd == "" then
    return
  end
  if s.sudo == true then
    local esc = noctalia.getConfig("privilege_escalation") or "none"
    if esc ~= "none" then
      cmd = esc .. " " .. cmd
    end
  end
  noctalia.runAsync(cmd, function(result)
    if result.exitCode ~= 0 then
      noctalia.notifyError(title(s), noctalia.tr("status.error", { label = "" }))
    else
      noctalia.notify(title(s), noctalia.tr("status.ok", { label = "" }))
    end
    cache = { at = 0, scripts = nil } -- script list may have changed externally
  end)
end

local function scriptRow(s, i, score)
  local desc = s.description ~= nil and s.description ~= "" and s.description or (s.tooltip or s.cmd or "")
  if #desc == 0 then
    desc = noctalia.tr("launcher.run_hint")
  end
  return {
    id = "run:" .. i,
    title = title(s),
    subtitle = desc,
    glyph = s.glyph or "terminal-2",
    score = score,
  }
end

function onQuery(query)
  local trimmed = noctalia.string.trim(query or "")

  local scripts
  if cache.scripts ~= nil and noctalia.nowMs() - cache.at < CACHE_TTL_MS then
    scripts = cache.scripts
  else
    scripts = loadScripts()
    cache = { at = noctalia.nowMs(), scripts = scripts }
  end

  local rows = {}
  for i, s in ipairs(scripts) do
    if type(s) == "table" then
      local score = 0
      if trimmed ~= "" then
        score = noctalia.fuzzyScore(trimmed, title(s) .. " " .. tostring(s.cmd or "") .. " " .. tostring(s.description or ""))
        if score == nil then
          continue
        end
      end
      table.insert(rows, scriptRow(s, i, score))
    end
  end
  table.sort(rows, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    return a.title < b.title
  end)
  while #rows > RESULT_LIMIT do
    table.remove(rows)
  end
  table.insert(rows, {
    id = "open-panel",
    title = noctalia.tr("launcher.open"),
    subtitle = noctalia.tr("launcher.description"),
    glyph = "terminal-2",
    score = trimmed == "" and 0 or 1,
  })

  if #rows == 1 then
    -- Only the panel row: no scripts configured (or none matched).
    launcher.setResults(query, {
      {
        id = "open-panel",
        title = trimmed == "" and noctalia.tr("launcher.empty") or noctalia.tr("launcher.no_matches"),
        subtitle = noctalia.tr("launcher.description"),
        glyph = "search-off",
        score = 2,
      },
    })
    return
  end
  launcher.setResults(query, rows)
end

function onActivate(id)
  if type(id) ~= "string" or id == "" then
    return
  end
  if id == "open-panel" then
    noctalia.togglePanel(PANEL_ID)
    return
  end
  local idx = tonumber(string.match(id, "^run:(%d+)$"))
  if idx ~= nil then
    local scripts = loadScripts()
    run(scripts[idx])
  end
end
