#!/usr/bin/env lua

--[[
Grid Table Converter for Pandoc Preprocessing (Lua)

This script reads a Markdown document from stdin, identifies all pipe table blocks,
and converts them into visually aligned, Markdown-compatible grid tables that 
support merged cells and alignment.

Features:
- Detects standard pipe tables with alignment rows
- Parses alignment and merged cell markers (`>>`, `<<`, `^^`, ``)
- Calculates column widths for perfectly aligned grid borders
- Applies Markdown-safe padding to avoid accidental code block formatting
- Outputs the converted document to stdout
- Writes a debug copy to `_gridTables.md`

Designed for integration into Scrivener → Pandoc → Typst workflows via Pandocomatic.
]]

-- UTF-8 support
local utf8_ok, utf8 = pcall(require, "utf8")
if not utf8_ok then
  -- fall back to byte-length if lua-utf8 is not available
  utf8 = { len = function(s) return #s end }
end

-- Helper functions

-- Splits a Markdown pipe table row into trimmed cell values
local function split_line(line)
    local cells = {}
    for cell in line:gmatch("[^|]+") do
        cell = cell:match("^%s*(.-)%s*$")
        table.insert(cells, cell)
    end
    return cells
end

-- Extracts {ti} rows from raw body and splits into header rows + remaining body
local function extract_ti_header_rows(raw_body_lines)
    local header_lines = {}
    local body_lines = {}

    for _, line in ipairs(raw_body_lines) do
        if line:find("{ti}") then
            local cleaned = line:gsub("{ti}", "")
            table.insert(header_lines, cleaned)
        else
            table.insert(body_lines, line)
        end
    end

    return header_lines, body_lines
end


-- Parses alignment markers (:---, ---:, :---:) into alignment config
local function parse_alignment(line)
    local aligns = {}
    for cell in line:gmatch("[^|]+") do
        cell = cell:match("^%s*(.-)%s*$")
        if cell ~= "" then
          if cell:match("^:%-+:$") then
              table.insert(aligns, {type = "center", shift = 2})
          elseif cell:match("^:%-+$") then
              table.insert(aligns, {type = "left", shift = 1})
          elseif cell:match("^%-+:$") then
              table.insert(aligns, {type = "right", shift = 1})
          elseif cell:match("^%-+$") then
              table.insert(aligns, {type = "left", shift = 0})
          else
              -- malformed segment; mark as nil to trigger validator
              table.insert(aligns, nil)
          end
        end
    end
    return aligns
end

-- Merges headers using >> and << markers to calculate colspan
local function merge_headers(header)
    local row = {}
    for _, cell in ipairs(header) do
        table.insert(row, {text = cell, span = 1})
    end

    local i = 1
    while i <= #row do
        local cell = row[i]
        if cell.text == ">>" and i > 1 then
            row[i - 1].span = row[i - 1].span + 1
            table.remove(row, i)
        elseif cell.text == "<<" and i < #row then
            row[i + 1].span = row[i + 1].span + 1
            table.remove(row, i)
        else
            i = i + 1
        end
    end

    return row
end

-- Parses and applies cell merging markers in table body
local function process_body_grid(raw_lines)
    local grid = {}
    for _, line in ipairs(raw_lines) do
        local raw = split_line(line)
        local row = {}
        for _, cell in ipairs(raw) do
            table.insert(row, {text = cell, span = 1, rowspan = 1, merged = false})
        end
        table.insert(grid, row)
    end
    if #grid == 0 then return grid end

    local rows, cols = #grid, #grid[1]

    for r = 1, rows do
        local row, i = grid[r], 1
        while i <= #row do
            local cell = row[i]
            if cell.text == ">>" and i > 1 then
                row[i - 1].span = row[i - 1].span + 1
                table.remove(row, i)
            elseif cell.text == "<<" and i < #row then
                row[i + 1].span = row[i + 1].span + 1
                table.remove(row, i)
            else
                i = i + 1
            end
        end
    end

    for c = 1, cols do
        for r = 1, rows do
            local cell = grid[r][c]
            if cell and not cell.merged then
                if cell.text == "^^" and r > 1 then
                    local above = grid[r - 1][c]
                    if above and not above.merged then
                        above.rowspan = (above.rowspan or 1) + 1
                        cell.merged = true
                        cell.text = ""
                    end
                elseif cell.text == "``" and r < rows then
                    local below = grid[r + 1][c]
                    if below and not below.merged then
                        cell.rowspan = (cell.rowspan or 1) + 1
                        cell.text = below.text
                        below.merged = true
                        below.text = ""
                    end
                end
            end
        end
    end

    return grid
end

-- Calculates the maximum column width from header + body
local function calculate_column_widths(header, body_grid)
    local max_width = 0
    for _, cell in ipairs(header) do
        local cell_width = utf8.len(cell.text)
        if cell.span == 1 then
            max_width = math.max(max_width, cell_width)
        else
            max_width = math.max(max_width, math.ceil(cell_width / cell.span))
        end
    end
    for _, row in ipairs(body_grid) do
        for _, cell in ipairs(row) do
            if not cell.merged then
                local width_each = math.ceil(utf8.len(cell.text) / cell.span)
                max_width = math.max(max_width, width_each)
            end
        end
    end
    local num_cols = 0
    for _, cell in ipairs(header) do num_cols = num_cols + cell.span end
    local col_widths = {}
    for i = 1, num_cols do col_widths[i] = max_width end
    return col_widths
end

-- Pads content based on alignment, avoids too many left spaces
local function pad_cell(text, total_width, align)
    local text_len = utf8.len(text)
    local pad_total = total_width - text_len
    if pad_total < 0 then pad_total = 0 end

    -- Safe max left padding to avoid triggering Markdown code block
    local safe_left = 3
    local left, right

    if align.type == "right" then
        left = pad_total - 1
        right = 1
    elseif align.type == "center" then
        left = math.floor(pad_total / 2)
        right = pad_total - left
    else -- left align
        left = 1
        right = pad_total - 1
    end

    if left < 0 then left = 0 end
    if right < 0 then right = 0 end

    -- Adjust left padding to max 3 spaces
    if left > safe_left then
        local overflow = left - safe_left
        left = safe_left
        right = right + overflow
    end

    return string.rep(" ", left) .. text .. string.rep(" ", right)
end

-- Creates a horizontal border line (+-----+-----+) for the grid table
local function generate_border(col_widths, aligns, char, merge_down_flags)
    local border = "+"
    for i = 1, #col_widths do
        local width = col_widths[i] + 2 + (aligns[i] and aligns[i].shift or 0)
        if merge_down_flags and merge_down_flags[i] then
            border = border .. string.rep(" ", width)
        else
            border = border .. string.rep(char, width)
        end
        border = border .. "+"
    end
    return border
end

-- Converts a full table block (header+align+body) into grid format
local function convert_pipe_to_grid(lines)
    local header_row = split_line(lines[1])
    local aligns = parse_alignment(lines[2])
    local top_header = {merge_headers(header_row)}
    
    -- Separate {ti} header rows from body lines
    local raw_body = {}
    for i = 3, #lines do table.insert(raw_body, lines[i]) end
    local ti_header_lines, body_lines = extract_ti_header_rows(raw_body)
    
    for _, line in ipairs(ti_header_lines) do
        local cells = split_line(line)
        local merged = merge_headers(cells)
        table.insert(top_header, merged)
    end
    
    local body = process_body_grid(body_lines)
    local widths = calculate_column_widths(top_header[1], body)

    local output = {}
    -- Render top border
    local idx = 1
    local top = "+"
    for _, cell in ipairs(top_header[1]) do
        local span_width = 0
        for _ = 1, cell.span do
            local a = aligns[idx] or {shift = 0}
            span_width = span_width + widths[idx] + 2 + a.shift
            idx = idx + 1
        end
        span_width = span_width + (cell.span - 1)
        top = top .. string.rep("-", span_width) .. "+"
    end
    table.insert(output, top)
    
    -- Render all header lines with optional inner border
    for i, row in ipairs(top_header) do
        local header_line = "|"
        local cidx = 1
        for _, cell in ipairs(row) do
            local span_width = 0
            local align = aligns[cidx] or {type = "left", shift = 0}
            for _ = 1, cell.span do
                local a = aligns[cidx] or {shift = 0}
                span_width = span_width + widths[cidx] + 2 + a.shift
                cidx = cidx + 1
            end
            span_width = span_width + (cell.span - 1)
            header_line = header_line .. pad_cell(cell.text, span_width, align) .. "|"
        end
        table.insert(output, header_line)
    
        -- Insert a horizontal line between header rows
        local is_last_header_row = (i == #top_header)
        if not is_last_header_row then
            table.insert(output, generate_border(widths, aligns, "-", nil))
        end
    end

    -- Double separator with alignment hints
    local separator = "+"
    for i, w in ipairs(widths) do
        local a = aligns[i] or {type = "left", shift = 0}
        local total = w + 2 + a.shift
        local seg = ""
        if a.type == "center" then
            seg = ":" .. string.rep("=", math.max(0, total - 2)) .. ":"
        elseif a.type == "right" then
            seg = string.rep("=", math.max(0, total - 1)) .. ":"
        elseif a.type == "left" and a.shift == 1 then
            seg = ":" .. string.rep("=", math.max(0, total - 1))
        else
            seg = string.rep("=", total)
        end
        separator = separator .. seg:sub(1, total) .. "+"
    end
    table.insert(output, separator)

    -- Body rows
    for _, row in ipairs(body) do
        local line = "|"
        local col = 1
        for _, cell in ipairs(row) do
            local span_width = 0
            local align = aligns[col] or {type = "left", shift = 0}
            for _ = 1, cell.span do
                local a = aligns[col] or {shift = 0}
                span_width = span_width + widths[col] + 2 + a.shift
                col = col + 1
            end
            span_width = span_width + (cell.span - 1)
            if not cell.merged then
                local text = (cell.text == "^^" or cell.text == "``") and "" or cell.text
                line = line .. pad_cell(text, span_width, align) .. "|"
            else
                line = line .. string.rep(" ", span_width) .. "|"
            end
        end
        table.insert(output, line)

        local flags, c = {}, 1
        for _, cell in ipairs(row) do
            if not cell.merged and cell.rowspan and cell.rowspan > 1 then
                for _ = 1, cell.span do flags[c] = true; c = c + 1 end
            else
                c = c + cell.span
            end
        end
        table.insert(output, generate_border(widths, aligns, "-", flags))
    end

    return output
end

-- Detects if a line looks like a pipe table row
local function is_pipe_table_line(line)
    return line:match("^%s*|.*|%s*$")
end

-- STRICT: Detects if a line is an alignment row (e.g. |:---|---:|) and only contains -, :, and spaces
local function is_alignment_row(line)
    if not line:match("^%s*|") then return false end
    local ok, have_any = true, false
    for cell in line:gmatch("[^|]+") do
        local s = (cell:match("^%s*(.-)%s*$")) or ""
        if s ~= "" then
            have_any = true
            if not (s:match("^:%-+:$") or s:match("^:%-+$") or s:match("^%-+:$") or s:match("^%-+$")) then
                ok = false; break
            end
        end
    end
    return ok and have_any
end

-- Validate a candidate table block quickly; if invalid, caller should pass it through unchanged
local function table_block_is_valid(block)
    if #block < 2 then return false end
    local header_cells = split_line(block[1])
    local align_cells  = parse_alignment(block[2])

    -- counts must match and all alignment segments must be recognized (non-nil)
    if #header_cells ~= #align_cells then return false end
    for i = 1, #align_cells do
        if align_cells[i] == nil then return false end
    end

    -- each body row must have same raw cell count as header (before merges)
    for i = 3, #block do
        local body_cells = split_line(block[i])
        if #body_cells ~= #header_cells then
            return false
        end
    end
    return true
end

-- Reads lines from stdin
local lines = {}
for line in io.lines() do
    table.insert(lines, line)
end

-- Process and transform tables in-memory
local output_lines = {}
local i = 1
while i <= #lines do
  local line = lines[i]
  local handled = false

  if is_pipe_table_line(line) then
    -- Case A: header line followed by alignment line
    if i < #lines and is_alignment_row(lines[i + 1]) and not is_alignment_row(line) then
      local start_i = i
      local table_block = { lines[i], lines[i + 1] }
      i = i + 2
      while i <= #lines and is_pipe_table_line(lines[i]) do
        table.insert(table_block, lines[i])
        i = i + 1
      end
      local ok, res = pcall(convert_pipe_to_grid, table_block, start_i)
      if ok then
        for _, gl in ipairs(res) do table.insert(output_lines, gl) end
      else
        io.stderr:write(string.format(
          "::: [grid-pre] skipped malformed table starting at line %d: %s\n",
          start_i, tostring(res)))
        for _, gl in ipairs(table_block) do table.insert(output_lines, gl) end
      end
      handled = true

    -- Case B: alignment-first table (no explicit header line)
    elseif is_alignment_row(line) and (i == 1 or not is_pipe_table_line(lines[i - 1])) then
      local start_i = i
      local align_line = lines[i]
    
      -- Build a synthetic empty header row with the same number of columns as the alignment row
      local function count_cols(s)
        local n = 0
        for _ in s:gmatch("[^|]+") do n = n + 1 end
        return n
      end
      local ncols = count_cols(align_line)
      -- Create a header like "| | | ... |" (ncols cells)
      local empties = {}
      for _ = 1, ncols do table.insert(empties, " ") end
      local fake_header = "|" .. table.concat(empties, "|") .. "|"
    
      -- Now collect the full table: header (fake), alignment, then body rows
      local table_block = { fake_header, align_line }
      i = i + 1
      while i <= #lines and is_pipe_table_line(lines[i]) do
        table.insert(table_block, lines[i])
        i = i + 1
      end
    
      local ok, res = pcall(convert_pipe_to_grid, table_block, start_i)
      if ok then
        for _, gl in ipairs(res) do table.insert(output_lines, gl) end
      else
        io.stderr:write(string.format(
          "::: [grid-pre] skipped malformed table starting at line %d: %s\n",
          start_i, tostring(res)))
        for _, gl in ipairs(table_block) do table.insert(output_lines, gl) end
      end
      handled = true
    end

  end

  if not handled then
    table.insert(output_lines, line or "")
    i = i + 1
  end
end


-- Write to stdout
for _, line in ipairs(output_lines) do
    io.write(line .. "\n")
end

-- Debug copy (always try to write to CWD)
local out, err = io.open("_gridTables.md", "w")
if out then
    for _, line in ipairs(output_lines) do
        out:write(line .. "\n")
    end
    out:close()
    io.stderr:write("[grid-pre] wrote debug file: _gridTables.md\n")
else
    io.stderr:write("❌ Failed to write to _gridTables.md: " .. tostring(err) .. "\n")
end
