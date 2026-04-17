#! /usr/bin/env lua
-- typstCleanup.lua (UTF-8 safe)

-- ===== typstCleanup helpers (no collisions) =====
local tc_DEBUG = true
local tc_log = tc_DEBUG and io.open("typstFix_debug.log", "a") or nil
local function tc_dbg(s)
  if tc_log then tc_log:write(tostring(s) .. "\n"); tc_log:flush() end
end

-- Ensure utf8 module is available (Lua 5.3+ usually has it; require makes it explicit)
local ok_utf8, utf8 = pcall(require, "utf8")
if not ok_utf8 or type(utf8) ~= "table" then
  error("typstCleanup.lua: missing utf8 module (need Lua 5.3+ or a build with utf8)")
end

local function tc_file_exists(p)
  local f = io.open(p, "rb")
  if f then f:close(); return true end
  return false
end

-- ===== UTF-8 safe plain-string replacement (NO patterns) =====
local function tc_replace_plain(s, from, to)
  if from == "" then return s end
  local start = 1
  while true do
    local i, j = string.find(s, from, start, true) -- plain find
    if not i then break end
    s = string.sub(s, 1, i - 1) .. to .. string.sub(s, j + 1)
    start = i + #to
  end
  return s
end

-- Superscripts inside <...> labels → ASCII
local tc_supers = {
  ["¹"]="1",["²"]="2",["³"]="3",["⁴"]="4",["⁵"]="5",
  ["⁶"]="6",["⁷"]="7",["⁸"]="8",["⁹"]="9",["⁰"]="0",
}

local function tc_normalize_label_supers(line)
  if not line:match("<[^>]+>") then return line end
  return line:gsub("(<[^>]+>)", function(label)
    return (label:gsub("[%z\1-\127\194-\244][\128-\191]*", function(ch)
      return tc_supers[ch] or ch
    end))
  end)
end

-- Collapse doubled list markers at line start:
-- "- - item" → "  - item", "+ + item" → "  + item" (repeatable)
local function tc_fix_double_list_markers(lines)
  for i = 1, #lines do
    local s, changed = lines[i], false
    while true do
      local a, n = s:gsub("^(%s*)[-+]%s+([-+])%s+", "%1  %2 ")
      s = a
      if n == 0 then break end
      changed = true
    end
    if changed then
      lines[i] = s
      tc_dbg(("fix_double: %d -> %s"):format(i, s))
    end
  end
end

-- Inject list/enum spacing rules based on item length.
-- Rule: '+' starts enum, '-' starts bullet. Short list → 0.65em, long → 1.2em.
local function tc_inject_list_spacing(lines)
  local out, cur, inside, kind = {}, {}, false, nil
  local function is_blank(l) return l:match("^%s*$") ~= nil end
  local function is_indented(l) return l:match("^%s+") ~= nil end
  local function marker(l) return l:match("^%s*([+-])%s+") end
  local function spacing_for(list)
    for _, item in ipairs(list) do
      if #item:gsub("\n", "") > 60 then return "1.2em" end
    end
    return "0.65em"
  end
  local function flush()
    if not inside or #cur == 0 then return end
    local sp = spacing_for(cur)
    local rule = (kind == "enum") and ("#set enum(spacing: " .. sp .. ")")
      or ("#set list(spacing: " .. sp .. ")")
    table.insert(out, rule)
    for _, l in ipairs(cur) do table.insert(out, l) end
    cur, inside, kind = {}, false, nil
  end

  for _, l in ipairs(lines) do
    local m = marker(l)
    if m then
      if not inside then inside = true; kind = (m == "+") and "enum" or "bullet" end
      table.insert(cur, l)
    elseif inside and (is_indented(l) or is_blank(l)) then
      table.insert(cur, l)
    else
      if inside then flush() end
      table.insert(out, l)
    end
  end
  if inside then flush() end
  return out
end

-- === New: SVG layer reorderer (text/labels on top of boxes) ===
local function tc_reorder_svg_layers_inplace(path_svg)
  local f = io.open(path_svg, "r")
  if not f then
    tc_dbg("reorder_svg: file not found " .. tostring(path_svg))
    return
  end
  local content = f:read("*a")
  f:close()
  if not content:match("<svg") then
    tc_dbg("reorder_svg: not an SVG, skipping " .. tostring(path_svg))
    return
  end

  local open_tag, inner, close_tag = content:match("(<svg.-%>)([%z\1-\255]*)(</svg%s*>)")
  if not inner then
    tc_dbg("reorder_svg: could not isolate inner for " .. path_svg)
    return
  end

  local body = inner
  local texts, labels, shapes = {}, {}, {}

  body = body:gsub("(<text.-</text>)", function(chunk)
    table.insert(texts, chunk)
    return ""
  end)

  body = body:gsub("(<g[^>]-class=[\"'][^\"']-label[^\"']*[\"'][^>]->.-</g>)", function(chunk)
    table.insert(labels, chunk)
    return ""
  end)

  body = body:gsub("(<(rect|path|polygon)[^>]->.-</%2>)", function(chunk)
    table.insert(shapes, chunk)
    return ""
  end)

  local rebuilt = open_tag
    .. table.concat(shapes, "")
    .. body
    .. table.concat(labels, "")
    .. table.concat(texts, "")
    .. close_tag

  if rebuilt ~= content then
    local wf = io.open(path_svg, "w")
    if wf then
      wf:write(rebuilt)
      wf:close()
      tc_dbg("reorder_svg: updated " .. path_svg)
    end
  else
    tc_dbg("reorder_svg: no change for " .. path_svg)
  end
end

-- Replace <foreignObject> blocks (HTML labels) with plain <text> (no font/size scaling)
local function tc_remove_foreign_objects(svg_path)
  local f = io.open(svg_path, "r"); if not f then return end
  local content = f:read("*a"); f:close()
  local original_content = content

  if not content:lower():find("foreignobject", 1, true) then return end

  local function xml_escape(s)
    s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    return s
  end

  local function wrap_line_to_width(line, maxc)
    local out, cur = {}, ""
    for word in tostring(line):gmatch("%S+") do
      if #cur == 0 then
        cur = word
      elseif #cur + 1 + #word <= maxc then
        cur = cur .. " " .. word
      else
        table.insert(out, cur); cur = word
      end
    end
    if #cur > 0 then table.insert(out, cur) end
    return out
  end

  local n_paired
  content, n_paired = content:gsub(
    "(<%s*[%w:]*[Ff]oreignObject[^>]*>)([%z\1-\255]-)</%s*[%w:]*[Ff]oreignObject%s*>",
    function(openTag, inner)
      local w = tonumber((openTag:match('width%s*=%s*"([%d%.]+)"') or openTag:match("width%s*=%s*'([%d%.]+)'") or "120")) or 120
      local h = tonumber((openTag:match('height%s*=%s*"([%d%.]+)"') or openTag:match("height%s*=%s*'([%d%.]+)'") or "24")) or 24
      local x = tonumber(openTag:match('x%s*=%s*"([%d%.%-]+)"') or openTag:match("x%s*=%s*'([%d%.%-]+)'") or "0") or 0
      local y = tonumber(openTag:match('y%s*=%s*"([%d%.%-]+)"') or openTag:match("y%s*=%s*'([%d%.%-]+)'") or "0") or 0
      local transform = openTag:match('transform%s*=%s*"([^"]+)"') or openTag:match("transform%s*=%s*'([^']+)'")

      local cx, cy = x + w/2, y + h/2

      inner = inner
        :gsub("</p>%s*<p>", "\n")
        :gsub("<br%s*/?>", "\n")
        :gsub("&nbsp;", " ")
        :gsub("&amp;",  "&")

      inner = inner:gsub("&lt;", "__TC_LT__"):gsub("&gt;", "__TC_GT__")
      inner = inner:gsub("<%s*/?%s*[%w:._%-]+[^>]*>", " ")
      inner = inner:gsub("__TC_LT__", "&lt;"):gsub("__TC_GT__", "&gt;")
      inner = inner:gsub("[ \t]+", " "):gsub("^%s+", ""):gsub("%s+$","")

      local max_chars = math.max(1, math.floor(w / 9.6))

      local logical = {}
      for line in tostring(inner):gmatch("[^\n]+") do table.insert(logical, line) end
      if #logical == 0 then logical = { inner } end

      local lines = {}
      for _, ln in ipairs(logical) do
        local wrapped = wrap_line_to_width(ln, max_chars)
        if #wrapped == 0 then table.insert(lines, "") else
          for _, wln in ipairs(wrapped) do table.insert(lines, wln) end
        end
      end
      if #lines == 0 then lines = { "" } end

      local line_h_em = 1.25
      local offset_em = -((#lines - 1) / 2) * line_h_em

      local parts = {}
      if transform then parts[#parts+1] = string.format('<g transform="%s">', transform) end
      parts[#parts+1] = '<text text-anchor="middle" dominant-baseline="middle" xml:space="preserve">'
      for i, txt in ipairs(lines) do
        txt = txt:gsub("&lt;", "<"):gsub("&gt;", ">")
        txt = xml_escape(txt)
        if i == 1 then
          parts[#parts+1] = string.format('<tspan x="%.3f" y="%.3f" dy="%.4fem">%s</tspan>', cx, cy, offset_em, txt)
        else
          parts[#parts+1] = string.format('<tspan x="%.3f" dy="%.4fem">%s</tspan>', cx, line_h_em, txt)
        end
      end
      parts[#parts+1] = '</text>'
      if transform then parts[#parts+1] = '</g>' end
      return table.concat(parts)
    end
  )

  local n_self
  content, n_self = content:gsub("<%s*[%w:]*[Ff]oreignObject[^>]*/%s*>", "")

  local total = (n_paired or 0) + (n_self or 0)
  if total > 0 then tc_dbg(("foreignObject: removed %d block(s)"):format(total)) end

  local function tc_balanced(svg)
    local opens_any = select(2, svg:gsub("<%s*[Gg][^>]*>", ""))
    local closes    = select(2, svg:gsub("</%s*[Gg]%s*>", ""))
    local self      = select(2, svg:gsub("<%s*[Gg][^>]-/%s*>", ""))
    return (opens_any - self) == closes
  end

  local out = io.open(svg_path, "w")
  if out then
    if tc_balanced(content) then
      out:write(content)
    else
      tc_dbg("ABORT rewrite (unbalanced <g> tags): " .. svg_path)
      out:write(original_content)
    end
    out:close()
  end
end

local function tc_fix_edge_orphans(svg_path)
  local f = io.open(svg_path, "r"); if not f then return end
  local svg = f:read("*a"); f:close()
  local changed = 0
  svg = svg:gsub('(<g[^>]-class=["\'][^"\']*edgeLabel[^"\']*["\'][^>]*>.-</g>)', function(block)
    local before = block
    for _ = 1, 3 do
      block = block:gsub('(<tspan[^>]*>[^<]-)</tspan>%s*<tspan([^>]*)>(%S%S?)</tspan>',
                         '%1&#160;%3</tspan>')
    end
    if block ~= before then changed = changed + 1 end
    return block
  end)
  if changed > 0 then
    local w = io.open(svg_path, "w"); if w then w:write(svg); w:close() end
  end
end

-- === Simplified image/label rewrite (no PDF conversion) ===
local function tc_rewrite_images_and_labels(lines)
  for i, l in ipairs(lines) do
    lines[i] = tc_normalize_label_supers(l)
  end

  local all = table.concat(lines, "\n")
  local seen = {}
  for svg in all:gmatch('image%(%s*"([^"]+%.svg)"') do
    if not seen[svg] then
      seen[svg] = true
      tc_dbg("found svg: " .. svg)
      tc_remove_foreign_objects(svg)
      tc_fix_edge_orphans(svg)
      -- Optional:
      -- tc_reorder_svg_layers_inplace(svg)
    end
  end
end

-- ===== PDF/A-safe character replacements (ONLY tack symbols) =====
-- Typst uses "=>" as function syntax, so we MUST NOT replace arrows like "=>" or "->" etc.
-- We ONLY replace ⊣ / ⊢ (and optionally -| / |- shorthands) into Typst math.

local U = utf8.char
local SYM = {
  RTACK = U(0x22A3), -- ⊣
  LTACK = U(0x22A2), -- ⊢
}

local tc_pdfa_ordered = {
  { SYM.RTACK, "$tack.l$" },
  { SYM.LTACK, "$tack.r$" },
  { "-|",      "$tack.l$" },
  { "|-",      "$tack.r$" },
}

local function tc_pdfa_safe_line(line)
  if not line:find(SYM.RTACK, 1, true)
     and not line:find(SYM.LTACK, 1, true)
     and not line:find("-|", 1, true)
     and not line:find("|-", 1, true)
  then
    return line
  end

  local orig = line
  for _, kv in ipairs(tc_pdfa_ordered) do
    local k, v = kv[1], kv[2]
    if line:find(k, 1, true) then
      line = tc_replace_plain(line, k, v)
    end
  end

  if line ~= orig then
    tc_dbg("pdfa_safe: " .. orig .. "  =>  " .. line)
  end
  return line
end

-- ===== minimal main using tc_* helpers only =====
local function process_typst_input()
  local lines = {}

  -- Read stdin line-by-line, applying PDF/A-safe filter first
  for L in io.lines() do
    table.insert(lines, tc_pdfa_safe_line(L))
  end

  tc_fix_double_list_markers(lines)
  lines = tc_inject_list_spacing(lines)
  tc_rewrite_images_and_labels(lines)

  for _, L in ipairs(lines) do
    io.write(L, "\n")
  end
end

process_typst_input()
if tc_log then tc_log:close() end