#!/usr/bin/env lua

local io = require("io")
local string = require("string")
local os = require("os")

-- Function to convert PDF to SVG
local function pdf_to_svg(pdf_path)
    local svg_path = pdf_path:gsub("%.pdf$", ".svg")
    local command = string.format("pdf2svg %q %q", pdf_path, svg_path)
    local success = os.execute(command)
    if success then
        return svg_path
    else
        io.stderr:write("Error: Failed to convert PDF to SVG: " .. pdf_path .. "\n")
        return nil
    end
end

-- Resolve relative path to absolute
local function resolve_path(base_dir, filename)
    return base_dir .. "/" .. filename
end

-- Main function to process Typst content from stdin
local function process_typst_input()
    local input_lines = {}
    local output_lines = {}
    local base_dir = io.popen("pwd"):read("*l") -- Get current working directory

    -- Read all lines from stdin
    for line in io.lines() do
        table.insert(input_lines, line)
    end

    -- Process each line to find and convert PDFs to SVGs
    for _, line in ipairs(input_lines) do
        local pdf_path = line:match('image%("([^"]+%.pdf)"%)')
        if pdf_path then
            local full_pdf_path = resolve_path(base_dir, pdf_path)
            local svg_path = pdf_to_svg(full_pdf_path)
            if svg_path then
                -- Get just the filename without the path
                local filename = svg_path:match("[^/]+$")
                line = line:gsub(pdf_path, filename)
            else
                io.stderr:write("Error: Conversion failed for PDF: " .. full_pdf_path .. "\n")
            end
        end
        table.insert(output_lines, line)
    end

    -- Write all processed lines to stdout
    for _, line in ipairs(output_lines) do
        print(line)
    end
end

-- Execute the processing function
process_typst_input()
