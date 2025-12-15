--[[
Markdown has no concept of tabs and replaces them with spaces.
Therefore I replace tabs in Scrivener with "!TAB!" during
compilation. This filter replaces this back to "\t" on the pandoc AST.
]]--


function Str(el)
  -- Replace every occurrence of !TAB! with a tab character
  local modified_text = el.text:gsub("!TAB!", "\t") -- 8 spaces
  return pandoc.Str(modified_text)
end