#! /usr/bin/env lua

-- Function to check if a line is a list item (starting with - or +)
local function is_list_item(line)
    return line:match("^%s*[-+]%s+")
end

-- Function to check if a line is indented (for multi-line list items)
local function is_indented(line)
    return line:match("^%s+") ~= nil
end

-- Function to determine if any item in the list exceeds 50 characters
local function calculate_spacing(list)
    for _, item in ipairs(list) do
        -- Count characters in the item, ignoring newlines
        local char_count = #item:gsub("\n", "")
        if char_count > 50 then
            return 24  -- Set to 24pt if any item exceeds 50 characters
        end
    end
    return 12  -- Default to 12pt if all items are under 50 characters
end

-- Main function to process the Typst input
local function process_typst_input()
    local lines = {}
    for line in io.lines() do
        table.insert(lines, line)
    end

    local output = {}
    local current_list = {}
    local inside_list = false  -- Tracks whether we are inside a list

    for i, line in ipairs(lines) do
        -- Check if the current line starts a list item
        if is_list_item(line) then
            -- If starting a new list, set inside_list to true
            if not inside_list then
                inside_list = true
            end
            table.insert(current_list, line)  -- Add line to current list
        elseif inside_list and is_indented(line) then
            -- If inside a list and the line is indented, it's part of the current item
            table.insert(current_list, line)
        else
            -- If an empty line or non-list line ends a list
            if inside_list and (not is_list_item(line) and line:match("^%s*$")) then
                -- Determine spacing and add a single set rule for the entire list
                local spacing = calculate_spacing(current_list)
                if spacing == 12 then
                    table.insert(output, "#set list(spacing: 0.65em)")
                else
                    table.insert(output, "#set list(spacing: 1.2em)")
                end
                for _, item in ipairs(current_list) do
                    table.insert(output, item)
                end
                current_list = {}  -- Clear list for the next list block
                inside_list = false  -- End list context
            end
            -- Add the non-list line to output
            table.insert(output, line)
        end
    end

    -- Handle any remaining list if the input ends with a list
    if inside_list and #current_list > 0 then
        local spacing = calculate_spacing(current_list)
        if spacing == 12 then
            table.insert(output, "#set list(spacing: 0.65em)")
        else
            table.insert(output, "#set list(spacing: 1.2em)")
        end
        for _, item in ipairs(current_list) do
            table.insert(output, item)
        end
    end

    -- Write the output to stdout
    for _, line in ipairs(output) do
        print(line)
    end
end

-- Execute the processing function
process_typst_input()
