--[[
  fixDivforNonDOCX.lua
  --------------------
  A Pandoc Lua filter to convert Divs with custom styles into native lists
  for LaTeX and Typst outputs, and leave other formats (e.g., DOCX) untouched.

  Main entry point:
    function Div(elem)
      Checks elem.attributes['custom-style'] and FORMAT to dispatch.

  LaTeX handling (FORMAT == "latex"):
    • "List Bullet Custom":
        - Groups the Div’s content blocks into bullet‐items, merging
          nested OrderedList/BulletList blocks into the same item.
        - Emits a LaTeX itemize environment:
            \begin{itemize}
              \item <first line of each item>
              [indented nested lists]
            \end{itemize}

    • "List Number":
        - Same grouping logic as bullets.
        - Emits an enumerate environment:
            \begin{enumerate}
              \item <first line of each item>
              [indented nested lists]
            \end{enumerate}

    Grouping logic (processList):
      1) Iterate over paragraphs (Para) that are non‐empty:
         • Start a new listItem with pandoc.Plain(blk.content)
         • Consume any immediately following OrderedList or BulletList blocks
           and append them into listItem.
      2) Wrap any other block types as singleton items.
      3) Return array of listItems (each itself an array of blocks).

    Rendering:
      • Build raw LaTeX items by prefixing `\item ` as RawInline.
      • Render nested lists by calling pandoc.write on a Pandoc corpus,
        indenting every line before inserting as RawBlock.

  Typst handling (FORMAT matches "typst"):
    • "List Bullet Custom" and "List Number":
        - Reuse the same processList grouping.
        - Convert grouped blocks into pandoc.BulletList or pandoc.OrderedList.
        - Walk the resulting list block and replace all Para nodes with Plain,
          ensuring correct inline‐only items for Typst renderer.

  Other formats:
    • For formats that can natively handle Div-based custom‐style lists
      (e.g., DOCX), the filter leaves Div elements unmodified.

  Utilities:
    – pandoc.utils.stringify: to test for blank paragraphs.
    – pandoc.walk_block: to transform Para → Plain in the final AST.
    – pandoc.RawInline / RawBlock: to inject raw LaTeX directives.
--]]



function Div(elem)
  if FORMAT == "latex" then

    if elem.attributes['custom-style'] == "List Bullet Custom" then

      -- 1) group the Div’s blocks into list‑items exactly as we do for numbers
      local function processList(blocks)
        local items, i = {}, 1
        while i <= #blocks do
          local blk = blocks[i]
          if blk.t == "Para"
             and not pandoc.utils.stringify(blk):match("^%s*$")
          then
            local listItem = { pandoc.Plain(blk.content) }
            i = i + 1
            while i <= #blocks
              and (blocks[i].t == "OrderedList" or blocks[i].t == "BulletList")
            do
              table.insert(listItem, blocks[i])
              i = i + 1
            end
            table.insert(items, listItem)
          else
            table.insert(items, { blk })
            i = i + 1
          end
        end
        return items
      end

      local grouped = processList(elem.content)
      local out     = {}

      -- open environment
      table.insert(out, pandoc.RawBlock("latex", "\\begin{itemize}"))

      for _, listItem in ipairs(grouped) do
        -- emit the \item + text
        local first = listItem[1]  -- a Plain
        local inln  = { pandoc.RawInline("latex", "\\item ") }
        for _, x in ipairs(first.content) do
          table.insert(inln, x)
        end
        table.insert(out, pandoc.Plain(inln))

        -- now any nested lists
        for j = 2, #listItem do
          local sub = listItem[j]
          if sub.t == "OrderedList" or sub.t == "BulletList" then
            -- keep it in the same \item
            table.insert(out, pandoc.RawBlock("latex", ""))

            -- re-render the nested list as LaTeX
            local latex_nested = pandoc.write(
              pandoc.Pandoc({ sub }),
              "latex"
            )

            -- indent every line by two spaces
            local indented = latex_nested:gsub("\n", "\n  ")
            table.insert(out, pandoc.RawBlock("latex", "  " .. indented))
          end
        end
      end

      -- close environment
      table.insert(out, pandoc.RawBlock("latex", "\\end{itemize}"))
      return out

    elseif elem.attributes['custom-style'] == "List Number" then

      -- 1) group the Div’s blocks into list‑items
      local function processList(blocks)
        local items, i = {}, 1
        while i <= #blocks do
          local blk = blocks[i]
          if blk.t == "Para"
             and not pandoc.utils.stringify(blk):match("^%s*$")
          then
            local listItem = { pandoc.Plain(blk.content) }
            i = i + 1
            while i <= #blocks
              and (blocks[i].t == "OrderedList" or blocks[i].t == "BulletList")
            do
              table.insert(listItem, blocks[i])
              i = i + 1
            end
            table.insert(items, listItem)
          else
            table.insert(items, { blk })
            i = i + 1
          end
        end
        return items
      end

      local grouped = processList(elem.content)
      local out     = {}

      -- open outer enumerate
      table.insert(out, pandoc.RawBlock("latex", "\\begin{enumerate}"))

      for _, listItem in ipairs(grouped) do
        -- emit the \item + text
        local first = listItem[1]  -- a Plain
        local inln  = { pandoc.RawInline("latex", "\\item ") }
        for _, x in ipairs(first.content) do
          table.insert(inln, x)
        end
        table.insert(out, pandoc.Plain(inln))

        -- now any nested lists
        for j = 2, #listItem do
          local sub = listItem[j]
          if sub.t == "OrderedList" or sub.t == "BulletList" then
            -- blank line so it stays in the same \item
            table.insert(out, pandoc.RawBlock("latex", ""))

            -- re-render the nested list as LaTeX
            local latex_nested = pandoc.write(
              pandoc.Pandoc({ sub }),
              "latex"
            )

            -- indent every line by two spaces
            local indented = latex_nested:gsub("\n", "\n  ")
            table.insert(out, pandoc.RawBlock("latex", "  " .. indented))
          end
        end
      end

      -- close enumerate
      table.insert(out, pandoc.RawBlock("latex", "\\end{enumerate}"))
      return out
    end

  elseif FORMAT:match("typst") then

    if elem.attributes['custom-style'] == "List Bullet Custom" then

      -- 1) exactly the same grouping as for numbered lists:
      local function processList(blocks)
        local items, i = {}, 1
        while i <= #blocks do
          local blk = blocks[i]
          -- start a new bullet-item on a non-empty Para
          if blk.t == "Para"
             and not pandoc.utils.stringify(blk):match("^%s*$")
          then
            local listItem = { pandoc.Plain(blk.content) }
            i = i + 1
            -- gobble up nested OrderedList/BulletList blocks
            while i <= #blocks
              and (blocks[i].t == "OrderedList"
                or blocks[i].t == "BulletList")
            do
              table.insert(listItem, blocks[i])
              i = i + 1
            end
            table.insert(items, listItem)
          else
            -- anything else becomes its own item
            table.insert(items, { blk })
            i = i + 1
          end
        end
        return items
      end

      -- do the grouping
      local grouped = processList(elem.content)

      -- 2) build the BulletList, then smash every Para → Plain
      local lst = pandoc.BulletList(grouped)
      lst = pandoc.walk_block(lst, {
        Para = function(el)
          return pandoc.Plain(el.content)
        end
      })

      -- 3) hand it back
      return lst

    elseif elem.attributes['custom-style'] == "List Number" then

      -- 1) group the Div’s blocks into list‑items exactly as before
      local function processList(blocks)
        local items, i = {}, 1
        while i <= #blocks do
          local blk = blocks[i]
          if blk.t == "Para"
             and not pandoc.utils.stringify(blk):match("^%s*$")
          then
            local listItem = { pandoc.Plain(blk.content) }
            i = i + 1
            while i <= #blocks
              and (blocks[i].t == "OrderedList"
                or blocks[i].t == "BulletList")
            do
              table.insert(listItem, blocks[i])
              i = i + 1
            end
            table.insert(items, listItem)
          else
            table.insert(items, { blk })
            i = i + 1
          end
        end
        return items
      end

      local grouped = processList(elem.content)

      -- 2) build the OrderedList, then walk it to replace every Para → Plain
      local lst = pandoc.OrderedList(grouped)
      lst = pandoc.walk_block(lst, {
        Para = function(el)
          return pandoc.Plain(el.content)
        end
      })

      -- 3) return the cleaned‑up list
      return lst
    end
  end

  -- For docx or any other format that can handle div elements, do nothing
  return elem
end


-- highlight-to-typst.lua
-- Convert [ ... ]{custom-style="Highlight [color]"} to Typst #highlight(fill: ...)[...]
-- Default mapping makes "blue" -> "aqua" on Typst for a brighter blue.

-- ----- CONFIG: default color mapping -----
-- Keys are lower-case logical names you use in Scrivener ("yellow", "blue", ...).
-- Values are Typst color expressions (named, rgb(...), or 0xHEX) for Typst,
-- and plain names for LaTeX's \colorbox{...}.
local DEFAULT_MAP = {
  yellow = { typst = "yellow",  latex = "yellow" },
  blue   = { typst = "aqua", latex = "blue"   },  -- brighter blue in Typst
  green  = { typst = "green",   latex = "green"  },
  red    = { typst = "red",     latex = "red"    },
  aqua   = { typst = "aqua",    latex = "cyan"   },
  navy   = { typst = "navy",    latex = "blue"   },
}

-- Optionally override via document metadata, e.g. in YAML:
-- highlight-colors:
--   blue: "0x1E90FF"
--   yellow: "rgb(255,240,130)"
local META_MAP = nil

-- Serialize inlines to Typst so wrapping stays clean
local function render_inlines_as_typst(inlines)
  local doc = pandoc.Pandoc({ pandoc.Para(inlines) })
  local out = pandoc.write(doc, "typst")
  return (out:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Pull optional metadata overrides
function Meta(meta)
  if meta["highlight-colors"] then
    META_MAP = {}
    for k, v in pairs(meta["highlight-colors"]) do
      local key = tostring(k):lower()
      local val = pandoc.utils.stringify(v)
      META_MAP[key] = val
    end
  end
end

-- Parse custom-style like "Highlight", "Highlight blue", etc.
local function parse_highlight(style)
  if not style then return nil end
  local s = style:lower()
  local base, color = s:match("^%s*(highlight)%s*(.*)%s*$")
  if base ~= "highlight" then return nil end
  color = (color or ""):match("^%s*(.-)%s*$")
  if color == "" then color = "yellow" end
  return color
end

-- Resolve the color to use for the current FORMAT
local function resolve_color(logical_color)
  local lc = logical_color or "yellow"

  if FORMAT:match("typst") then
    -- metadata override has priority
    if META_MAP and META_MAP[lc] and META_MAP[lc] ~= "" then
      return META_MAP[lc] -- raw Typst expr like "0x1E90FF" or "rgb(0,128,255)"
    end
    -- default mapping
    local rec = DEFAULT_MAP[lc]
    if rec and rec.typst then return rec.typst end
    return "yellow"
  elseif FORMAT == "latex" then
    local rec = DEFAULT_MAP[lc]
    if rec and rec.latex then return rec.latex end
    return "yellow"
  else
    return nil
  end
end

function Span(el)
  local color_key = parse_highlight(el.attributes and el.attributes["custom-style"])
  if not color_key then return nil end

  if FORMAT:match("typst") then
    local fill = resolve_color(color_key)
    local inner = render_inlines_as_typst(el.content)
    local raw
    if fill:match("^%s*rgb%(") or fill:match("^%s*0x[%da-fA-F]+%s*$") or fill:match("^[%a][%w-]*$") then
      raw = string.format("#highlight(fill: %s)[%s]", fill, inner)
    else
      -- If someone sets something exotic, just pass through
      raw = string.format("#highlight(fill: %s)[%s]", fill, inner)
    end
    return pandoc.RawInline("typst", raw)

  elseif FORMAT == "latex" then
    local fill = resolve_color(color_key)
    local out = { pandoc.RawInline("latex", "\\colorbox{" .. fill .. "}{") }
    for _, x in ipairs(el.content) do table.insert(out, x) end
    table.insert(out, pandoc.RawInline("latex", "}"))
    return out

  else
    -- Other formats: drop styling, keep content
    return el.content
  end
end
