#!/usr/bin/env lua

local io = require("io")
local string = require("string")
local os = require("os")

-- PDF/A standards that block PDF embedding
local PDFA_STANDARDS = {
  ["a-1b"]=true, ["a-1a"]=true,
  ["a-2b"]=true, ["a-2u"]=true, ["a-2a"]=true,
  ["a-3b"]=true, ["a-3u"]=true, ["a-3a"]=true,
  ["a-4"]=true,  ["a-4f"]=true, ["a-4e"]=true,
  ["ua-1"]=true,
}

-- Read pdf-standard from the typst content
-- Pandoc writes metadata as: #let pdf-standard = "a-3u" or similar
-- We also check for a plain comment we can inject, or just scan all lines
local function read_pdf_standard(lines)
  for _, line in ipairs(lines) do
    -- match: pdf-standard: "a-3u" (from YAML passed through as metadata)
    local val = line:match('pdf%-standard%s*:%s*"?([%w%-%.]+)"?')
    if val then return val end
    -- match Typst let binding: #let pdf-standard = "a-3u"
    val = line:match('#let%s+pdf%-standard%s*=%s*"([^"]+)"')
    if val then return val end
  end
  return "1.7" -- default: not PDF/A
end

-- Function to convert PDF to SVG using inkscape (preferred: handles D2 PDFs correctly)
local function pdf_to_svg(pdf_path)
  local svg_path = pdf_path:gsub("%.pdf$", ".svg")
  local command = string.format(
    "inkscape --export-type=svg --export-plain-svg --export-filename=%q %q",
    svg_path, pdf_path
  )
  local success = os.execute(command)
  if success then
    return svg_path
  else
    io.stderr:write("typst_PDF_converter: Failed to convert PDF to SVG: " .. pdf_path .. "\n")
    return nil
  end
end

-- Alternative: convert PDF to SVG using pdf2svg
-- Simpler but rasterizes content in D2-produced PDFs (embeds PNG inside SVG).
-- To switch back: comment out the inkscape function above and uncomment this one.
--
-- local function pdf_to_svg(pdf_path)
--   local svg_path = pdf_path:gsub("%.pdf$", ".svg")
--   local command = string.format("pdf2svg %q %q", pdf_path, svg_path)
--   local success = os.execute(command)
--   if success then
--     return svg_path
--   else
--     io.stderr:write("typst_PDF_converter: Failed to convert PDF to SVG: " .. pdf_path .. "\n")
--     return nil
--   end
-- end

local function resolve_path(base_dir, filename)
  return base_dir .. "/" .. filename
end

local function process_typst_input()
  local input_lines = {}
  local output_lines = {}
  local base_dir = io.popen("pwd"):read("*l")

  for line in io.lines() do
    table.insert(input_lines, line)
  end

  -- Check if we need to convert at all
  local pdf_standard = read_pdf_standard(input_lines)
  local needs_conversion = PDFA_STANDARDS[pdf_standard:lower()] == true

  if not needs_conversion then
    -- Pass through unchanged
    for _, line in ipairs(input_lines) do
      print(line)
    end
    return
  end

  io.stderr:write("typst_PDF_converter: PDF/A mode (" .. pdf_standard .. "), converting PDFs to SVG\n")

  -- Convert any image("*.pdf") references
  local seen = {}
  for _, line in ipairs(input_lines) do
    local pdf_path = line:match('image%("([^"]+%.pdf)"%)')
    if pdf_path and not seen[pdf_path] then
      seen[pdf_path] = true
      local full_pdf_path = resolve_path(base_dir, pdf_path)
      local svg_path = pdf_to_svg(full_pdf_path)
      if svg_path then
        local filename = svg_path:match("[^/]+$")
        line = line:gsub(pdf_path, filename)
      else
        io.stderr:write("typst_PDF_converter: Conversion failed for: " .. full_pdf_path .. "\n")
      end
    elseif pdf_path and seen[pdf_path] then
      -- already converted, just rewrite the reference
      local svg_name = pdf_path:gsub("%.pdf$", ".svg")
      line = line:gsub(pdf_path, svg_name)
    end
    table.insert(output_lines, line)
  end

  for _, line in ipairs(output_lines) do
    print(line)
  end
end

process_typst_input()
