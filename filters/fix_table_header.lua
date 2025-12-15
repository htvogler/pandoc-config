local stringify = pandoc.utils.stringify

local function escape_typst(s)
  return s:gsub("\\", "\\\\")
           :gsub("#", "\\#")
           :gsub("%^", "\\^")
           :gsub("_", "\\_")
end

local function stringify_cell(cell)
  return escape_typst(stringify(cell))
end

local function convert_to_typst_table(tbl)
  local num_cols = #tbl.colspec
  local num_header_rows = #tbl.head.rows

  local align_map = {
    AlignLeft = "left",
    AlignRight = "right",
    AlignCenter = "center",
    AlignDefault = "left"
  }

  local alignments = {}
  for _, spec in ipairs(tbl.colspec) do
    table.insert(alignments, align_map[spec[1].t] or "left")
  end

  local function fmt_row(row)
    local cells = {}
    for _, cell in ipairs(row.cells) do
      table.insert(cells, stringify_cell(cell))
    end
    return "[" .. table.concat(cells, ", ") .. "]"
  end

  local header_rows = {}
  for _, row in ipairs(tbl.head.rows) do
    table.insert(header_rows, fmt_row(row))
  end

  local body_rows = {}
  for _, body in ipairs(tbl.bodies) do
    for _, row in ipairs(body.rows) do
      table.insert(body_rows, fmt_row(row))
    end
  end

  local typst = {}
  table.insert(typst, "mytable(")
  table.insert(typst, "  columns: " .. num_cols .. ",")
  table.insert(typst, "  align: (" .. table.concat(alignments, ", ") .. "),")
  table.insert(typst, "  header-rows: " .. num_header_rows .. ",")
  table.insert(typst, "  header: [")
  table.insert(typst, "    " .. table.concat(header_rows, ",\n    "))
  table.insert(typst, "  ],")
  table.insert(typst, "  body: [")
  table.insert(typst, "    " .. table.concat(body_rows, ",\n    "))
  table.insert(typst, "  ]")
  table.insert(typst, ")")

  return table.concat(typst, "\n"), num_header_rows
end

function Table(el)
  if FORMAT ~= "typst" then return nil end

  local num_header_rows = #(el.head and el.head.rows or {})

  -- Let Pandoc write the table as Typst
  local table_code = pandoc.write(pandoc.Pandoc({el}), "typst")

  -- Wrap the table code in a call to the style function with brackets
  local wrapped = "#set_table_style(" .. num_header_rows .. ")[\n" .. table_code .. "\n]"

  return pandoc.RawBlock("typst", wrapped)
end




function Pandoc(doc)
  -- optional: save the final AST for debugging
  local json = pandoc.write(doc, "json")
  local file = io.open("_ast.json", "w")
  if file then
    file:write(json)
    file:close()
  end
  return doc
end

