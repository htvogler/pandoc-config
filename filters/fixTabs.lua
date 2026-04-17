--[[
Markdown has no concept of tabs and replaces them with spaces.
Therefore I replace tabs in Scrivener with "!TAB!" during
compilation. This filter replaces this back to "\t" on the pandoc AST.
]]--


-- fixTabs.lua
-- Typst/typst-citations: convert tabbed paragraphs into a borderless left-aligned grid.
-- Others (docx for now): restore real tab characters.

local MARKER = "!TAB!"

-- Treat both "typst" and "typst-*" writers (e.g. typst-citations) as Typst targets.
local function is_typst_format()
  return FORMAT == "typst" or FORMAT:match("^typst") ~= nil
end

local function is_tabbed_block(b)
  if b.t ~= "Para" and b.t ~= "Plain" then return false end
  for _, il in ipairs(b.content) do
    if il.t == "Str" and il.text:find(MARKER, 1, true) then
      return true
    end
  end
  return false
end

local function split_inlines_to_cells(inlines)
  local cells = { {} }
  local function new_cell() table.insert(cells, {}) end

  for _, il in ipairs(inlines) do
    if il.t == "Str" then
      local text = il.text
      local start = 1
      while true do
        local i, j = text:find(MARKER, start, true)
        if not i then
          local tail = text:sub(start)
          if tail ~= "" then table.insert(cells[#cells], pandoc.Str(tail)) end
          break
        end
        local head = text:sub(start, i - 1)
        if head ~= "" then table.insert(cells[#cells], pandoc.Str(head)) end
        new_cell()
        start = j + 1
      end
    else
      table.insert(cells[#cells], il)
    end
  end

  return cells
end

local function inlines_to_typst(inlines)
  -- Serialize inline formatting safely using pandoc's typst writer.
  -- NOTE: Always write as "typst" here because we just want typst syntax for content.
  local tmp = pandoc.Pandoc({ pandoc.Plain(inlines) })
  local s = pandoc.write(tmp, "typst")
  return (s:gsub("%s+$", ""))
end

local function make_typst_grid(rows)
  -- compute max columns
  local ncols = 0
  for _, r in ipairs(rows) do
    if #r > ncols then ncols = #r end
  end
  if ncols == 0 then return nil end

  -- pad ragged rows
  for _, r in ipairs(rows) do
    while #r < ncols do table.insert(r, {}) end
  end

  -- columns: first auto, rest 1fr
  local cols = {}
  for c = 1, ncols do
    cols[#cols + 1] = (c == 1) and "auto" or "1fr"
  end

  local out = {}
  -- IMPORTANT:
  -- We wrap in #context so par.leading is valid.
  -- Inside the braces we are already in code mode, so do NOT prefix with '#'.
  out[#out + 1] = "#context {"
  out[#out + 1] = "  align(left)["
  out[#out + 1] = "    #grid("
  out[#out + 1] = "      columns: (" .. table.concat(cols, ", ") .. "),"
  out[#out + 1] = "      align: left,"
  out[#out + 1] = "      stroke: none,"
  out[#out + 1] = "      inset: (x: 0pt, y: 0pt),"
  out[#out + 1] = "      column-gutter: 1em,"
  out[#out + 1] = "      row-gutter: par.leading,"

  for _, r in ipairs(rows) do
    for _, cell_inlines in ipairs(r) do
      local cell = inlines_to_typst(cell_inlines)
      out[#out + 1] = "      [" .. cell .. "],"
    end
  end

  out[#out + 1] = "    )"
  out[#out + 1] = "  ]"
  out[#out + 1] = "}"

  -- CRITICAL FIX:
  -- Use the *actual* output format (FORMAT), e.g. "typst-citations",
  -- so Pandoc passes it through as native raw code instead of emitting a `raw(...)` node.
  return pandoc.RawBlock(FORMAT, table.concat(out, "\n"))
end

-- Keep DOCX behavior (and others for now): restore \t
function Str(el)
  if (not is_typst_format()) and el.text:find(MARKER, 1, true) then
    return pandoc.Str(el.text:gsub(MARKER, "\t"))
  end
  return el
end

function Pandoc(doc)
  if not is_typst_format() then
    return doc
  end

  local out = {}
  local acc = {}

  local function flush()
    if #acc == 0 then return end
    local grid = make_typst_grid(acc)
    if grid then out[#out + 1] = grid end
    acc = {}
  end

  for _, b in ipairs(doc.blocks) do
    if is_tabbed_block(b) then
      acc[#acc + 1] = split_inlines_to_cells(b.content)
    else
      flush()
      out[#out + 1] = b
    end
  end
  flush()

  doc.blocks = out
  return doc
end