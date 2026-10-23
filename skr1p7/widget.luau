--!nonstrict

local function render()
  barWidget.render(ui.glyph({ name = "terminal-2", size = 14 }))
  barWidget.setTooltip("Script Box")
end

function onClick()
  noctalia.togglePanel("noctalia/skr1p7:panel")
end

render()
