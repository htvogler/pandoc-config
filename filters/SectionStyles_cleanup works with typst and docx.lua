-- SectionStyles_cleanup.lua
--
-- A Pandoc Lua filter for a Scrivener → Pandocomatic → Pandoc workflow.
--
-- Supported custom structures:
--   1. Div class "multipart"
--   2. Div class "equationblock"
--   3. CodeBlock with attributes such as:
--        ```{.lua #lst-parser caption="Parser logic" linenos="true"}
--        ...
--        ```
--
-- Multipart notes:
--   - outer div caption comes ONLY from the outer div caption attribute
--   - outer div width/height are respected in Typst multipart output
--   - panel width/height may come from:
--       a) normal image attributes
--       b) normal figure attributes
--       c) trailing size tag in panel caption text, e.g.:
--            ![Control tray.{width=70%}](a.png)
--            ![Control tray. {width=70%, height=4cm}](a.png)
--            ![Control tray. {70%}](a.png)
--   - trailing caption size tags are stripped from visible captions
--   - percentage panel widths in Typst are converted to grid fractions
--     (e.g. 70% / 30% -> 0.7fr / 0.3fr)
--   - percentage panel widths are NOT applied twice to image(...)
--   - docx/odt/html fallback keeps grouped rows instead of separate figures
--   - debug comments for Typst multipart output are inserted into the generated
--     .typ source when DEBUG_MULTIPART is true

local List = require("pandoc.List")

local DEBUG_MULTIPART = true

local WORDISH_IMAGE_INSET = "96%"

-- ------------------------------------------------------------
-- Basic helpers
-- ------------------------------------------------------------

local function clean_attr(val)
  if val == nil then
    return nil
  end
  if type(val) ~= "string" then
    return val
  end
  local trimmed = val:match("^%s*(.-)%s*$")
  if trimmed == "" or trimmed == "(none)" or trimmed:lower() == "default" then
    return nil
  end
  return trimmed
end

local function split_classes(s)
  local out = {}
  s = clean_attr(s)
  if not s then
    return out
  end
  for cls in s:gmatch("%S+") do
    table.insert(out, cls)
  end
  return out
end

local function copy_attributes(attrs)
  local out = {}
  if not attrs then
    return out
  end
  for k, v in pairs(attrs) do
    out[k] = v
  end
  return out
end

local function stringify_inlines(inlines)
  return pandoc.utils.stringify(inlines or {})
end

local function stringify_blocks(blocks)
  return pandoc.utils.stringify(blocks or {})
end

local function escape_typst_string(s)
  s = s or ""
  s = s:gsub("\\", "\\\\")
  s = s:gsub('"', '\\"')
  return s
end

local function escape_typst_content(s)
  s = s or ""
  s = s:gsub("\\", "\\\\")
  s = s:gsub("%[", "\\[")
  s = s:gsub("%]", "\\]")
  return s
end

local function escape_latex(s)
  s = s or ""
  s = s:gsub("\\", "\\textbackslash{}")
  s = s:gsub("([#$%%&_{}])", "\\%1")
  s = s:gsub("%^", "\\textasciicircum{}")
  s = s:gsub("~", "\\textasciitilde{}")
  return s
end

local function parse_bool(v, default)
  v = clean_attr(v)
  if v == nil then
    return default
  end
  v = v:lower()
  if v == "true" or v == "yes" or v == "1" then
    return true
  end
  if v == "false" or v == "no" or v == "0" then
    return false
  end
  return default
end

local function debug_string(v)
  if v == nil then
    return "nil"
  end
  return tostring(v)
end

local function debug_join(arr, sep)
  if not arr or #arr == 0 then
    return "nil"
  end
  return table.concat(arr, sep or " || ")
end

local function typst_comment_line(text)
  return "// " .. text
end

local function is_target_typst()
  return FORMAT:match("typst") ~= nil
end

local function is_target_latex()
  return FORMAT == "latex"
end

local function is_target_wordish()
  return FORMAT == "docx" or FORMAT == "odt"
end

local function is_target_ebookish()
  return FORMAT:match("epub") ~= nil
end

local function is_target_htmlish()
  return FORMAT:match("html") ~= nil
end

local function pandoc_blocks_to_typst(blocks)
  local doc = pandoc.Pandoc(blocks)
  local out = pandoc.write(doc, "typst")
  out = out:gsub("^%s+", ""):gsub("%s+$", "")
  return out
end

-- ------------------------------------------------------------
-- Literal inline/block text extraction
-- ------------------------------------------------------------

local function inline_debug_dump(inlines)
  if not inlines then
    return "nil"
  end

  local out = {}

  local function walk_inline(inl)
    if not inl then
      table.insert(out, "<nil-inline>")
      return
    end

    local t = inl.t or "?"
    if t == "Str" then
      table.insert(out, "Str(" .. debug_string(inl.text or inl.c or "") .. ")")
    elseif t == "Space" then
      table.insert(out, "Space")
    elseif t == "SoftBreak" then
      table.insert(out, "SoftBreak")
    elseif t == "LineBreak" then
      table.insert(out, "LineBreak")
    elseif t == "Code" then
      table.insert(out, "Code(" .. debug_string(inl.text or (type(inl.c) == "table" and inl.c[2]) or "") .. ")")
    elseif t == "Math" then
      table.insert(out, "Math(" .. debug_string(type(inl.c) == "table" and inl.c[2] or "") .. ")")
    elseif t == "RawInline" then
      table.insert(out, "RawInline(" .. debug_string(type(inl.c) == "table" and inl.c[2] or "") .. ")")
    else
      table.insert(out, t)
      if inl.content then
        for _, child in ipairs(inl.content) do
          walk_inline(child)
        end
      elseif type(inl.c) == "table" then
        for _, child in ipairs(inl.c) do
          if type(child) == "table" and child.t then
            walk_inline(child)
          end
        end
      end
    end
  end

  for _, inl in ipairs(inlines) do
    walk_inline(inl)
  end

  return table.concat(out, " | ")
end

local function block_debug_dump(blocks)
  if not blocks then
    return "nil"
  end

  local out = {}
  for _, blk in ipairs(blocks) do
    if blk.t == "Plain" or blk.t == "Para" then
      table.insert(out, blk.t .. "(" .. inline_debug_dump(blk.content or blk.c or {}) .. ")")
    else
      table.insert(out, blk.t or "?")
    end
  end
  return table.concat(out, " || ")
end

local function inline_list_to_literal_text(inlines)
  if not inlines then
    return nil
  end

  local out = {}

  local function walk_inline(inl)
    if not inl then
      return
    end

    local t = inl.t

    if t == "Str" then
      table.insert(out, inl.text or inl.c or "")
    elseif t == "Space" or t == "SoftBreak" or t == "LineBreak" then
      table.insert(out, " ")
    elseif t == "Code" then
      table.insert(out, inl.text or (type(inl.c) == "table" and inl.c[2]) or "")
    elseif t == "Math" then
      if type(inl.c) == "table" then
        table.insert(out, inl.c[2] or "")
      end
    elseif t == "RawInline" then
      if type(inl.c) == "table" then
        table.insert(out, inl.c[2] or "")
      end
    elseif inl.content then
      for _, child in ipairs(inl.content) do
        walk_inline(child)
      end
    elseif type(inl.c) == "table" then
      for _, child in ipairs(inl.c) do
        if type(child) == "table" and child.t then
          walk_inline(child)
        end
      end
    end
  end

  for _, inl in ipairs(inlines) do
    walk_inline(inl)
  end

  local s = table.concat(out)
  s = s:gsub("%s+", " ")
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  return s
end

local function block_list_to_literal_text(blocks)
  if not blocks then
    return nil
  end

  local parts = {}

  for _, blk in ipairs(blocks) do
    if blk.t == "Plain" or blk.t == "Para" then
      local s = inline_list_to_literal_text(blk.content or blk.c or {})
      if clean_attr(s) then
        table.insert(parts, s)
      end
    elseif blk.t == "CodeBlock" then
      table.insert(parts, blk.text or (type(blk.c) == "table" and blk.c[2]) or "")
    else
      local s = pandoc.utils.stringify({ blk })
      s = clean_attr(s)
      if s then
        table.insert(parts, s)
      end
    end
  end

  local joined = table.concat(parts, " ")
  joined = joined:gsub("%s+", " ")
  joined = joined:gsub("^%s+", ""):gsub("%s+$", "")
  return joined
end

-- ------------------------------------------------------------
-- Attribute access helpers
-- ------------------------------------------------------------

local function get_attr_object(el)
  if not el then
    return nil
  end

  if el.attr then
    return el.attr
  end

  if el.identifier ~= nil or el.classes ~= nil or el.attributes ~= nil then
    return pandoc.Attr(el.identifier or "", el.classes or {}, el.attributes or {})
  end

  return nil
end

local function get_identifier(el)
  if not el then
    return nil
  end

  if el.identifier and el.identifier ~= "" then
    return el.identifier
  end

  local attr = get_attr_object(el)
  if attr and attr.identifier and attr.identifier ~= "" then
    return attr.identifier
  end

  if attr and attr[1] and attr[1] ~= "" then
    return attr[1]
  end

  return nil
end

local function get_classes(el)
  local out = {}
  local seen = {}

  if el and el.classes then
    for _, c in ipairs(el.classes) do
      if c ~= "" and not seen[c] then
        seen[c] = true
        table.insert(out, c)
      end
    end
  end

  local attr = get_attr_object(el)
  if attr and attr.classes then
    for _, c in ipairs(attr.classes) do
      if c ~= "" and not seen[c] then
        seen[c] = true
        table.insert(out, c)
      end
    end
  elseif attr and attr[2] then
    for _, c in ipairs(attr[2]) do
      if c ~= "" and not seen[c] then
        seen[c] = true
        table.insert(out, c)
      end
    end
  end

  local attr_class_string = nil
  if el and el.attributes then
    attr_class_string = el.attributes["class"] or el.attributes["Class"]
  end
  if attr_class_string then
    for _, c in ipairs(split_classes(attr_class_string)) do
      if c ~= "" and not seen[c] then
        seen[c] = true
        table.insert(out, c)
      end
    end
  end

  return out
end

local function has_class(el, class_name)
  for _, c in ipairs(get_classes(el)) do
    if c == class_name then
      return true
    end
  end
  return false
end

local function get_attributes(el)
  local out = {}

  if el and el.attributes then
    for k, v in pairs(el.attributes) do
      out[k] = v
    end
  end

  local attr = get_attr_object(el)
  if attr and attr.attributes then
    for k, v in pairs(attr.attributes) do
      out[k] = v
    end
  elseif attr and attr[3] then
    for _, pair in ipairs(attr[3]) do
      if pair[1] then
        out[pair[1]] = pair[2]
      end
    end
  end

  return out
end

local function get_attr_ci_from_map(attrs, key)
  if not attrs or not key then
    return nil
  end

  if attrs[key] ~= nil then
    return attrs[key]
  end

  local want = key:lower()
  for k, v in pairs(attrs) do
    if type(k) == "string" and k:lower() == want then
      return v
    end
  end

  return nil
end

local function get_attr_ci(el, key)
  return get_attr_ci_from_map(get_attributes(el), key)
end

local function first_nonempty_attr(attrs, keys)
  for _, k in ipairs(keys) do
    local v = clean_attr(get_attr_ci_from_map(attrs, k))
    if v then
      return v
    end
  end
  return nil
end

local function first_nonempty_value(values)
  for _, v in ipairs(values or {}) do
    v = clean_attr(v)
    if v then
      return v
    end
  end
  return nil
end

-- ------------------------------------------------------------
-- Dimension helpers
-- ------------------------------------------------------------

local function normalize_dimension_for_raw_output(val)
  val = clean_attr(val)
  if not val then
    return nil
  end

  local lower = val:lower()

  if lower == "auto" then
    return val
  end
  if lower:match("^%-?[%d%.]+%%$") then
    return val
  end
  if lower:match("^%-?[%d%.]+fr$") then
    return val
  end
  if lower:match("^%-?[%d%.]+pt$") then
    return val
  end
  if lower:match("^%-?[%d%.]+mm$") then
    return val
  end
  if lower:match("^%-?[%d%.]+cm$") then
    return val
  end
  if lower:match("^%-?[%d%.]+in$") then
    return val
  end
  if lower:match("^%-?[%d%.]+em$") then
    return val
  end
  if lower:match("^%-?[%d%.]+ex$") then
    return val
  end

  return nil
end

local function parse_percent_value(dim)
  dim = clean_attr(dim)
  if not dim then
    return nil
  end
  local n = dim:match("^([%d%.]+)%%$")
  if n then
    return tonumber(n)
  end
  return nil
end

-- ------------------------------------------------------------
-- Caption-tag parsing
-- ------------------------------------------------------------

local function parse_trailing_panel_size_tag(text)
  text = clean_attr(text)
  if not text then
    return nil, nil, nil
  end

  local base, tag = text:match("^(.-)%s*%{([^{}]+)%}%s*$")
  if not tag then
    return text, nil, nil
  end

  local width = nil
  local height = nil

  tag = tag:gsub("%s+", "")

  local parts = {}
  for part in tag:gmatch("[^,]+") do
    table.insert(parts, part)
  end

  for _, part in ipairs(parts) do
    local k, v = part:match("^([%w_-]+)=(.+)$")
    if k and v then
      k = k:lower()
      local val = normalize_dimension_for_raw_output(v)
      if k == "width" then
        width = val
      elseif k == "height" then
        height = val
      end
    else
      local val = normalize_dimension_for_raw_output(part)
      if val then
        if not width then
          width = val
        elseif not height then
          height = val
        end
      end
    end
  end

  base = clean_attr(base) or ""
  return base, width, height
end

local function parse_trailing_panel_size_tag_debug(text)
  local dbg = {
    input = clean_attr(text),
    matched_base = nil,
    matched_tag = nil,
    normalized_tag = nil,
    parts = {},
    parsed_parts = {},
    width = nil,
    height = nil,
    cleaned = nil
  }

  local cleaned_input = clean_attr(text)
  if not cleaned_input then
    return nil, nil, nil, dbg
  end

  local base, tag = cleaned_input:match("^(.-)%s*%{([^{}]+)%}%s*$")
  dbg.matched_base = base
  dbg.matched_tag = tag

  if not tag then
    dbg.cleaned = cleaned_input
    return cleaned_input, nil, nil, dbg
  end

  local width = nil
  local height = nil
  local norm_tag = tag:gsub("%s+", "")
  dbg.normalized_tag = norm_tag

  local parts = {}
  for part in norm_tag:gmatch("[^,]+") do
    table.insert(parts, part)
    table.insert(dbg.parts, part)
  end

  for _, part in ipairs(parts) do
    local k, v = part:match("^([%w_-]+)=(.+)$")
    if k and v then
      local k_lower = k:lower()
      local val = normalize_dimension_for_raw_output(v)
      table.insert(dbg.parsed_parts, "kv:" .. part .. " => key=" .. k_lower .. ", value=" .. debug_string(val))
      if k_lower == "width" then
        width = val
      elseif k_lower == "height" then
        height = val
      end
    else
      local val = normalize_dimension_for_raw_output(part)
      table.insert(dbg.parsed_parts, "bare:" .. part .. " => value=" .. debug_string(val))
      if val then
        if not width then
          width = val
        elseif not height then
          height = val
        end
      end
    end
  end

  base = clean_attr(base) or ""
  dbg.cleaned = base
  dbg.width = width
  dbg.height = height

  return base, width, height, dbg
end

-- ------------------------------------------------------------
-- Raw-structure helpers for Pandoc version differences
-- ------------------------------------------------------------

local function get_image_caption_inlines_raw(img)
  if not img or not img.c then
    return nil
  end
  if img.c[2] then
    return img.c[2]
  end
  return nil
end

local function get_image_target_raw(img)
  if not img or not img.c then
    return nil, nil
  end
  local target = img.c[3]
  if type(target) == "table" then
    return target[1], target[2]
  end
  return nil, nil
end

local function get_figure_caption_text_raw(fig)
  if not fig or not fig.c then
    return nil, nil
  end

  local dbg = {
    caption_table_type = nil,
    caption_raw = nil,
    long_part_dump = nil,
    long_text = nil,
    short_part_dump = nil,
    short_text = nil,
    returned = nil
  }

  local caption = fig.c[2]
  dbg.caption_table_type = type(caption)
  dbg.caption_raw = debug_string(caption)

  if type(caption) ~= "table" then
    return nil, dbg
  end

  local long_part = caption[2]
  if long_part then
    dbg.long_part_dump = block_debug_dump(long_part)
    local long_text = block_list_to_literal_text(long_part)
    dbg.long_text = long_text
    if clean_attr(long_text) then
      dbg.returned = long_text
      return long_text, dbg
    end
  end

  local short_part = caption[1]
  if short_part then
    dbg.short_part_dump = inline_debug_dump(short_part)
    local short_text = inline_list_to_literal_text(short_part)
    dbg.short_text = short_text
    if clean_attr(short_text) then
      dbg.returned = short_text
      return short_text, dbg
    end
  end

  return nil, dbg
end

local function get_figure_body_blocks_raw(fig)
  if not fig or not fig.c then
    return nil
  end
  return fig.c[3]
end

-- ------------------------------------------------------------
-- Image / Figure extraction
-- ------------------------------------------------------------

local function get_image_dimensions(img)
  local attrs = get_attributes(img)
  local raw_width = get_attr_ci_from_map(attrs, "width")
  local raw_height = get_attr_ci_from_map(attrs, "height")
  local width = normalize_dimension_for_raw_output(raw_width)
  local height = normalize_dimension_for_raw_output(raw_height)
  return width, height, raw_width, raw_height
end

local function get_figure_dimensions(fig)
  if not fig then
    return nil, nil, nil, nil
  end
  local attrs = get_attributes(fig)
  local raw_width = get_attr_ci_from_map(attrs, "width")
  local raw_height = get_attr_ci_from_map(attrs, "height")
  local width = normalize_dimension_for_raw_output(raw_width)
  local height = normalize_dimension_for_raw_output(raw_height)
  return width, height, raw_width, raw_height
end

local function get_image_caption_inlines(img)
  if img.caption then
    return img.caption, "img.caption"
  end
  if img.content then
    return img.content, "img.content"
  end
  if img.alt then
    return img.alt, "img.alt"
  end

  local raw = get_image_caption_inlines_raw(img)
  if raw then
    return raw, "raw.c[2]"
  end

  return {}, "empty"
end

local function get_image_subcaption(img)
  local attrs = get_attributes(img)

  local dbg = {
    attrs_caption = nil,
    caption_source = nil,
    caption_inline_dump = nil,
    caption_text = nil,
    from_title = nil,
    raw_title = nil,
    raw_title_clean = nil,
    returned = nil
  }

  local from_attrs = first_nonempty_attr(
    attrs,
    { "subcaption", "caption", "panel-caption", "panel_caption" }
  )
  dbg.attrs_caption = from_attrs
  if from_attrs then
    dbg.returned = from_attrs
    return from_attrs, dbg
  end

  local caption_inlines, caption_source = get_image_caption_inlines(img)
  dbg.caption_source = caption_source
  dbg.caption_inline_dump = inline_debug_dump(caption_inlines)

  local caption_text = inline_list_to_literal_text(caption_inlines)
  dbg.caption_text = caption_text
  if clean_attr(caption_text) then
    dbg.returned = caption_text
    return caption_text, dbg
  end

  local from_title = clean_attr(img.title)
  dbg.from_title = from_title
  if from_title then
    dbg.returned = from_title
    return from_title, dbg
  end

  local _, raw_title = get_image_target_raw(img)
  dbg.raw_title = raw_title
  local raw_title_clean = clean_attr(raw_title)
  dbg.raw_title_clean = raw_title_clean
  if raw_title_clean then
    dbg.returned = raw_title_clean
    return raw_title_clean, dbg
  end

  return nil, dbg
end

local function get_figure_caption_text(fig)
  if not fig then
    return nil, {
      attrs_caption = nil,
      fig_caption_long_dump = nil,
      fig_caption_long_text = nil,
      fig_caption_short_dump = nil,
      fig_caption_short_text = nil,
      raw_dbg = nil,
      returned = nil
    }
  end

  local attrs = get_attributes(fig)

  local dbg = {
    attrs_caption = nil,
    fig_caption_long_dump = nil,
    fig_caption_long_text = nil,
    fig_caption_short_dump = nil,
    fig_caption_short_text = nil,
    raw_dbg = nil,
    returned = nil
  }

  local from_attrs = first_nonempty_attr(
    attrs,
    { "subcaption", "caption", "panel-caption", "panel_caption" }
  )
  dbg.attrs_caption = from_attrs
  if from_attrs then
    dbg.returned = from_attrs
    return from_attrs, dbg
  end

  if fig.caption then
    if fig.caption.long then
      dbg.fig_caption_long_dump = block_debug_dump(fig.caption.long)
      local long_text = block_list_to_literal_text(fig.caption.long)
      dbg.fig_caption_long_text = long_text
      if clean_attr(long_text) then
        dbg.returned = long_text
        return long_text, dbg
      end
    end
    if fig.caption.short then
      dbg.fig_caption_short_dump = inline_debug_dump(fig.caption.short)
      local short_text = inline_list_to_literal_text(fig.caption.short)
      dbg.fig_caption_short_text = short_text
      if clean_attr(short_text) then
        dbg.returned = short_text
        return short_text, dbg
      end
    end
  end

  local raw_text, raw_dbg = get_figure_caption_text_raw(fig)
  dbg.raw_dbg = raw_dbg
  if raw_text then
    dbg.returned = raw_text
    return raw_text, dbg
  end

  return nil, dbg
end

local function get_image_panel_label(img)
  return first_nonempty_attr(get_attributes(img), { "panel-label", "panel_label" })
end

local function get_figure_panel_label(fig)
  if not fig then
    return nil
  end
  return first_nonempty_attr(get_attributes(fig), { "panel-label", "panel_label" })
end

local function image_from_simple_figure(blk)
  if blk.t ~= "Figure" then
    return nil
  end

  local body = blk.content
  if not body then
    body = get_figure_body_blocks_raw(blk)
  end

  if not body or #body ~= 1 then
    return nil
  end

  local inner = body[1]
  if (inner.t == "Plain" or inner.t == "Para")
     and inner.content
     and #inner.content == 1
     and inner.content[1].t == "Image"
  then
    return inner.content[1]
  end

  if inner.c and #inner.c == 1 and inner.c[1].t == "Image" then
    return inner.c[1]
  end

  return nil
end

local function collect_multipart_panels(div)
  local panels = List:new()
  local trailing_blocks = List:new()

  for _, blk in ipairs(div.content or {}) do
    local fig_img = image_from_simple_figure(blk)
    if fig_img then
      panels:insert({
        image = fig_img,
        figure = blk
      })

    elseif blk.t == "Para" or blk.t == "Plain" then
      local images = List:new()
      local other_inlines = List:new()

      for _, inline in ipairs(blk.content or {}) do
        if inline.t == "Image" then
          images:insert({
            image = inline,
            figure = nil
          })
        else
          other_inlines:insert(inline)
        end
      end

      if #images > 0 and pandoc.utils.stringify(other_inlines):match("^%s*$") then
        for _, entry in ipairs(images) do
          panels:insert(entry)
        end
      else
        trailing_blocks:insert(blk)
      end

    else
      trailing_blocks:insert(blk)
    end
  end

  return panels, trailing_blocks
end

-- forward declaration
local get_panel_spec

local function resolve_panels(panels)
  local resolved = {}
  for _, entry in ipairs(panels) do
    table.insert(resolved, get_panel_spec(entry))
  end
  return resolved
end

local function derive_colspec_from_panels(resolved_panels, cols)
  local specs = {}
  local pct_values = {}
  local has_percent = false

  for i = 1, cols do
    local panel = resolved_panels[i]
    if panel then
      local pct = parse_percent_value(panel.width)
      pct_values[i] = pct
      if pct then
        has_percent = true
      end
    else
      pct_values[i] = nil
    end
  end

  if not has_percent then
    for _ = 1, cols do
      table.insert(specs, "1fr")
    end
    return specs
  end

  local specified_sum = 0
  local unspecified = 0

  for i = 1, cols do
    if pct_values[i] then
      specified_sum = specified_sum + pct_values[i]
    else
      unspecified = unspecified + 1
    end
  end

  local remaining = 100 - specified_sum
  local default_pct = 0

  if unspecified > 0 then
    if remaining > 0 then
      default_pct = remaining / unspecified
    else
      default_pct = 100 / cols
    end
  end

  for i = 1, cols do
    local pct = pct_values[i] or default_pct
    table.insert(specs, tostring(pct / 100) .. "fr")
  end

  return specs
end

get_panel_spec = function(entry)
  local img = entry.image or entry
  local fig = entry.figure

  local figure_subcaption_raw, figure_subcaption_dbg = get_figure_caption_text(fig)
  local image_subcaption_raw, image_subcaption_dbg = get_image_subcaption(img)

  local figure_subcaption = clean_attr(figure_subcaption_raw)
  local image_subcaption = clean_attr(image_subcaption_raw)

  local raw_subcaption = figure_subcaption or image_subcaption

  local cleaned_subcaption, tag_width, tag_height, parse_dbg =
    parse_trailing_panel_size_tag_debug(raw_subcaption)

  local img_width, img_height, img_width_raw, img_height_raw = get_image_dimensions(img)
  local fig_width, fig_height, fig_width_raw, fig_height_raw = get_figure_dimensions(fig)

  local width = first_nonempty_value({
    tag_width,
    img_width,
    fig_width
  })

  local height = first_nonempty_value({
    tag_height,
    img_height,
    fig_height
  })

  local panel_label = first_nonempty_value({
    get_image_panel_label(img),
    get_figure_panel_label(fig)
  })

  local caption_text = nil
  if cleaned_subcaption and cleaned_subcaption ~= "" and panel_label then
    caption_text = panel_label .. " " .. cleaned_subcaption
  elseif cleaned_subcaption and cleaned_subcaption ~= "" then
    caption_text = cleaned_subcaption
  elseif panel_label then
    caption_text = panel_label
  end

  local src = img.src
  local title = img.title or ""

  if not src then
    local raw_src, raw_title = get_image_target_raw(img)
    src = raw_src
    if title == "" and raw_title then
      title = raw_title
    end
  end

  return {
    src = src,
    title = title,
    caption = caption_text,
    width = width,
    height = height,
    attributes = copy_attributes(get_attributes(img)),
    classes = get_classes(img),
    identifier = get_identifier(img) or "",

    debug_figure_subcaption_raw = figure_subcaption_raw,
    debug_figure_subcaption = figure_subcaption,
    debug_image_subcaption_raw = image_subcaption_raw,
    debug_image_subcaption = image_subcaption,
    debug_raw_subcaption = raw_subcaption,
    debug_cleaned_subcaption = cleaned_subcaption,
    debug_tag_width = tag_width,
    debug_tag_height = tag_height,
    debug_img_width_raw = img_width_raw,
    debug_img_height_raw = img_height_raw,
    debug_img_width = img_width,
    debug_img_height = img_height,
    debug_fig_width_raw = fig_width_raw,
    debug_fig_height_raw = fig_height_raw,
    debug_fig_width = fig_width,
    debug_fig_height = fig_height,
    debug_final_width = width,
    debug_final_height = height,

    debug_parse_input = parse_dbg and parse_dbg.input or nil,
    debug_parse_matched_base = parse_dbg and parse_dbg.matched_base or nil,
    debug_parse_matched_tag = parse_dbg and parse_dbg.matched_tag or nil,
    debug_parse_normalized_tag = parse_dbg and parse_dbg.normalized_tag or nil,
    debug_parse_parts = parse_dbg and debug_join(parse_dbg.parts, " | ") or nil,
    debug_parse_parsed_parts = parse_dbg and debug_join(parse_dbg.parsed_parts, " | ") or nil,

    debug_figure_attrs_caption = figure_subcaption_dbg and figure_subcaption_dbg.attrs_caption or nil,
    debug_figure_figcaption_long_dump = figure_subcaption_dbg and figure_subcaption_dbg.fig_caption_long_dump or nil,
    debug_figure_figcaption_long_text = figure_subcaption_dbg and figure_subcaption_dbg.fig_caption_long_text or nil,
    debug_figure_figcaption_short_dump = figure_subcaption_dbg and figure_subcaption_dbg.fig_caption_short_dump or nil,
    debug_figure_figcaption_short_text = figure_subcaption_dbg and figure_subcaption_dbg.fig_caption_short_text or nil,
    debug_figure_returned = figure_subcaption_dbg and figure_subcaption_dbg.returned or nil,
    debug_figure_raw_caption_type = figure_subcaption_dbg and figure_subcaption_dbg.raw_dbg and figure_subcaption_dbg.raw_dbg.caption_table_type or nil,
    debug_figure_raw_long_part_dump = figure_subcaption_dbg and figure_subcaption_dbg.raw_dbg and figure_subcaption_dbg.raw_dbg.long_part_dump or nil,
    debug_figure_raw_long_text = figure_subcaption_dbg and figure_subcaption_dbg.raw_dbg and figure_subcaption_dbg.raw_dbg.long_text or nil,
    debug_figure_raw_short_part_dump = figure_subcaption_dbg and figure_subcaption_dbg.raw_dbg and figure_subcaption_dbg.raw_dbg.short_part_dump or nil,
    debug_figure_raw_short_text = figure_subcaption_dbg and figure_subcaption_dbg.raw_dbg and figure_subcaption_dbg.raw_dbg.short_text or nil,
    debug_figure_raw_returned = figure_subcaption_dbg and figure_subcaption_dbg.raw_dbg and figure_subcaption_dbg.raw_dbg.returned or nil,

    debug_image_attrs_caption = image_subcaption_dbg and image_subcaption_dbg.attrs_caption or nil,
    debug_image_caption_source = image_subcaption_dbg and image_subcaption_dbg.caption_source or nil,
    debug_image_caption_inline_dump = image_subcaption_dbg and image_subcaption_dbg.caption_inline_dump or nil,
    debug_image_caption_text = image_subcaption_dbg and image_subcaption_dbg.caption_text or nil,
    debug_image_from_title = image_subcaption_dbg and image_subcaption_dbg.from_title or nil,
    debug_image_raw_title = image_subcaption_dbg and image_subcaption_dbg.raw_title or nil,
    debug_image_raw_title_clean = image_subcaption_dbg and image_subcaption_dbg.raw_title_clean or nil,
    debug_image_returned = image_subcaption_dbg and image_subcaption_dbg.returned or nil
  }
end

-- ------------------------------------------------------------
-- Multipart builders
-- ------------------------------------------------------------

local function derive_caption(div)
  return clean_attr(get_attr_ci(div, "caption"))
end

local function build_typst_image_expr(panel)
  local parts = {}
  table.insert(parts, 'image("' .. escape_typst_string(panel.src) .. '"')

  local pct = parse_percent_value(panel.width)
  if pct then
    table.insert(parts, ", width: 100%")
  elseif panel.width then
    table.insert(parts, ", width: " .. panel.width)
  else
    table.insert(parts, ", width: 100%")
  end

  if panel.height then
    table.insert(parts, ", height: " .. panel.height)
  end

  if panel.width and panel.height then
    table.insert(parts, ', fit: "stretch"')
  end

  table.insert(parts, ")")
  return table.concat(parts)
end

local function build_typst_panel_block(panel)
  local caption_text = panel.caption
  local panel_lines = {}

  if caption_text and caption_text ~= "" then
    table.insert(panel_lines, "          #figure(")
    table.insert(panel_lines, "            " .. build_typst_image_expr(panel) .. ",")
    table.insert(panel_lines, "            caption: [" .. escape_typst_content(caption_text) .. "],")
    table.insert(panel_lines, "            numbering: none,")
    table.insert(panel_lines, "            supplement: none,")
    table.insert(panel_lines, "            outlined: false,")
    table.insert(panel_lines, "          )")
  else
    table.insert(panel_lines, "          #" .. build_typst_image_expr(panel))
  end

  return table.concat(panel_lines, "\n")
end

local function typst_grid_align(halign, valign)
  local parts = {}

  if halign == "left" then
    table.insert(parts, "left")
  elseif halign == "right" then
    table.insert(parts, "right")
  else
    table.insert(parts, "center")
  end

  if valign == "top" then
    table.insert(parts, "top")
  elseif valign == "bottom" then
    table.insert(parts, "bottom")
  elseif valign == "center" or valign == "middle" then
    table.insert(parts, "horizon")
  end

  return table.concat(parts, " + ")
end

local function build_typst_multipart(div, panels, trailing_blocks)
  local cols = tonumber(clean_attr(get_attr_ci(div, "cols"))) or 2
  local align = clean_attr(get_attr_ci(div, "align"))
  local valign = clean_attr(get_attr_ci(div, "valign"))
  local gutter = clean_attr(get_attr_ci(div, "gutter")) or "1em"
  local caption = derive_caption(div)
  local label = get_identifier(div)

  local figure_width = normalize_dimension_for_raw_output(get_attr_ci(div, "width"))
  local figure_height = normalize_dimension_for_raw_output(get_attr_ci(div, "height"))

  local resolved_panels = resolve_panels(panels)
  local colspec = derive_colspec_from_panels(resolved_panels, cols)
  local grid_align = typst_grid_align(align, valign)

  local out = {}

  if DEBUG_MULTIPART then
    for i, panel in ipairs(resolved_panels) do
      table.insert(
        out,
        typst_comment_line(
          "DEBUG multipart resolved[" .. i .. "]: "
          .. "figure_subcaption_raw=" .. debug_string(panel.debug_figure_subcaption_raw)
          .. " | figure_subcaption=" .. debug_string(panel.debug_figure_subcaption)
          .. " | image_subcaption_raw=" .. debug_string(panel.debug_image_subcaption_raw)
          .. " | image_subcaption=" .. debug_string(panel.debug_image_subcaption)
          .. " | raw_subcaption=" .. debug_string(panel.debug_raw_subcaption)
          .. " | cleaned=" .. debug_string(panel.debug_cleaned_subcaption)
          .. " | tag_width=" .. debug_string(panel.debug_tag_width)
          .. " | tag_height=" .. debug_string(panel.debug_tag_height)
          .. " | img_width_raw=" .. debug_string(panel.debug_img_width_raw)
          .. " | img_height_raw=" .. debug_string(panel.debug_img_height_raw)
          .. " | img_width=" .. debug_string(panel.debug_img_width)
          .. " | img_height=" .. debug_string(panel.debug_img_height)
          .. " | fig_width_raw=" .. debug_string(panel.debug_fig_width_raw)
          .. " | fig_height_raw=" .. debug_string(panel.debug_fig_height_raw)
          .. " | fig_width=" .. debug_string(panel.debug_fig_width)
          .. " | fig_height=" .. debug_string(panel.debug_fig_height)
          .. " | final_width=" .. debug_string(panel.debug_final_width)
          .. " | final_height=" .. debug_string(panel.debug_final_height)
          .. " | caption=" .. debug_string(panel.caption)
          .. " | src=" .. debug_string(panel.src)
        )
      )

      table.insert(
        out,
        typst_comment_line(
          "DEBUG multipart parse[" .. i .. "]: "
          .. "input=" .. debug_string(panel.debug_parse_input)
          .. " | matched_base=" .. debug_string(panel.debug_parse_matched_base)
          .. " | matched_tag=" .. debug_string(panel.debug_parse_matched_tag)
          .. " | normalized_tag=" .. debug_string(panel.debug_parse_normalized_tag)
          .. " | parts=" .. debug_string(panel.debug_parse_parts)
          .. " | parsed_parts=" .. debug_string(panel.debug_parse_parsed_parts)
        )
      )

      table.insert(
        out,
        typst_comment_line(
          "DEBUG multipart figure-path[" .. i .. "]: "
          .. "attrs_caption=" .. debug_string(panel.debug_figure_attrs_caption)
          .. " | figcaption_long_dump=" .. debug_string(panel.debug_figure_figcaption_long_dump)
          .. " | figcaption_long_text=" .. debug_string(panel.debug_figure_figcaption_long_text)
          .. " | figcaption_short_dump=" .. debug_string(panel.debug_figure_figcaption_short_dump)
          .. " | figcaption_short_text=" .. debug_string(panel.debug_figure_figcaption_short_text)
          .. " | returned=" .. debug_string(panel.debug_figure_returned)
        )
      )

      table.insert(
        out,
        typst_comment_line(
          "DEBUG multipart figure-raw[" .. i .. "]: "
          .. "caption_type=" .. debug_string(panel.debug_figure_raw_caption_type)
          .. " | long_part_dump=" .. debug_string(panel.debug_figure_raw_long_part_dump)
          .. " | long_text=" .. debug_string(panel.debug_figure_raw_long_text)
          .. " | short_part_dump=" .. debug_string(panel.debug_figure_raw_short_part_dump)
          .. " | short_text=" .. debug_string(panel.debug_figure_raw_short_text)
          .. " | returned=" .. debug_string(panel.debug_figure_raw_returned)
        )
      )

      table.insert(
        out,
        typst_comment_line(
          "DEBUG multipart image-path[" .. i .. "]: "
          .. "attrs_caption=" .. debug_string(panel.debug_image_attrs_caption)
          .. " | caption_source=" .. debug_string(panel.debug_image_caption_source)
          .. " | caption_inline_dump=" .. debug_string(panel.debug_image_caption_inline_dump)
          .. " | caption_text=" .. debug_string(panel.debug_image_caption_text)
          .. " | from_title=" .. debug_string(panel.debug_image_from_title)
          .. " | raw_title=" .. debug_string(panel.debug_image_raw_title)
          .. " | raw_title_clean=" .. debug_string(panel.debug_image_raw_title_clean)
          .. " | returned=" .. debug_string(panel.debug_image_returned)
        )
      )
    end

    table.insert(
      out,
      typst_comment_line(
        "DEBUG multipart colspec: " .. table.concat(colspec, ", ")
      )
    )
  end

  table.insert(out, "#figure(")

  if caption then
    table.insert(out, "  caption: [" .. escape_typst_content(caption) .. "],")
  end

  if figure_width then
    table.insert(out, "  [#align(center)[")
    if figure_height then
      table.insert(out, "    #block(width: " .. figure_width .. ", height: " .. figure_height .. ")[")
    else
      table.insert(out, "    #block(width: " .. figure_width .. ")[")
    end
  elseif figure_height then
    table.insert(out, "  [#block(height: " .. figure_height .. ")[")
  else
    table.insert(out, "  [")
  end

  table.insert(out, "      #grid(")
  table.insert(out, "        columns: (" .. table.concat(colspec, ", ") .. "),")
  table.insert(out, "        gutter: " .. gutter .. ",")
  table.insert(out, "        align: " .. grid_align .. ",")

  for _, panel in ipairs(resolved_panels) do
    table.insert(out, "        [")
    table.insert(out, build_typst_panel_block(panel))
    table.insert(out, "        ],")
  end

  table.insert(out, "      )")

  if figure_width then
    table.insert(out, "    ]")
    table.insert(out, "  ]]")
  elseif figure_height then
    table.insert(out, "  ]]")
  else
    table.insert(out, "  ]")
  end

  if label then
    table.insert(out, ") <" .. label .. ">")
  else
    table.insert(out, ")")
  end

  return pandoc.RawBlock("typst", table.concat(out, "\n"))
end

local function build_latex_multipart(div, panels, trailing_blocks)
  local cols = tonumber(clean_attr(get_attr_ci(div, "cols"))) or 2
  local caption = derive_caption(div)
  local label = get_identifier(div)
  local figure_width = normalize_dimension_for_raw_output(get_attr_ci(div, "width"))

  local resolved_panels = resolve_panels(panels)

  local width_fraction = string.format("%.4f", 0.98 / cols)
  local out = {}

  table.insert(out, "\\begin{figure}[htbp]")
  table.insert(out, "\\centering")

  if figure_width then
    table.insert(out, "\\begin{minipage}{" .. figure_width .. "}")
    table.insert(out, "\\centering")
  end

  for i, panel in ipairs(resolved_panels) do
    table.insert(out, "\\begin{minipage}[b]{" .. width_fraction .. "\\linewidth}")
    table.insert(out, "\\centering")

    local include_opts = {}
    
    local pct = parse_percent_value(panel.width)
    if pct then
      table.insert(include_opts, string.format("width=%.4f\\linewidth", pct / 100))
    elseif panel.width then
      table.insert(include_opts, "width=" .. panel.width)
    else
      table.insert(include_opts, "width=\\linewidth")
    end
    
    if panel.height then
      table.insert(include_opts, "height=" .. panel.height)
    end

    table.insert(
      out,
      "\\includegraphics[" .. table.concat(include_opts, ",") .. "]{" .. panel.src .. "}"
    )

    if panel.caption and panel.caption ~= "" then
      table.insert(out, "\\par\\small\\emph{" .. escape_latex(panel.caption) .. "}")
    end

    table.insert(out, "\\end{minipage}")

    if i < #resolved_panels then
      if i % cols == 0 then
        table.insert(out, "\\par\\medskip")
      else
        table.insert(out, "\\hfill")
      end
    end
  end

  if figure_width then
    table.insert(out, "\\end{minipage}")
  end

  if caption then
    table.insert(out, "\\caption{" .. escape_latex(caption) .. "}")
  end

  if label then
    table.insert(out, "\\label{" .. label .. "}")
  end

  table.insert(out, "\\end{figure}")

  return pandoc.RawBlock("latex", table.concat(out, "\n"))
end

local function build_resolved_inline_image(panel)
  local attrs = copy_attributes(panel.attributes)

  if panel.width then
    attrs["width"] = panel.width
  else
    attrs["width"] = nil
  end

  if panel.height then
    attrs["height"] = panel.height
  else
    attrs["height"] = nil
  end

  local attr = pandoc.Attr(panel.identifier or "", panel.classes or {}, attrs)
  return pandoc.Image({}, panel.src, panel.title or "", attr)
end

local function caption_para_for_wordish(text)
  return pandoc.Para(
    { pandoc.Str(text) },
    pandoc.Attr("", {}, { ["custom-style"] = "Caption" })
  )
end

local function parse_length_value(dim)
  dim = clean_attr(dim)
  if not dim then
    return nil, nil
  end

  local n, unit = dim:match("^([%d%.]+)(cm|mm|in|pt)$")
  if not n then
    return nil, nil
  end

  return tonumber(n), unit
end

local function format_length_value(n, unit)
  if not n or not unit then
    return nil
  end
  
  local s = string.format("%.4f", n)
  s = s:gsub("0+$", "")
  s = s:gsub("%.$", "")
  return s .. unit
end

local function scale_length_value(dim, factor)
  local n, unit = parse_length_value(dim)
  if not n or not unit then
    return dim
  end
  return format_length_value(n * factor, unit)
end

local function compute_wordish_row_widths(row_panels, outer_width)
  local widths = {}
  local outer_n, outer_unit = parse_length_value(outer_width)

  local pct_values = {}
  local has_percent = false
  local specified_sum = 0
  local unspecified = 0

  for i, panel in ipairs(row_panels) do
    local pct = parse_percent_value(panel.width)
    pct_values[i] = pct
    if pct then
      has_percent = true
      specified_sum = specified_sum + pct
    else
      unspecified = unspecified + 1
    end
  end

  local default_pct = 0
  if unspecified > 0 then
    local remaining = 100 - specified_sum
    if remaining > 0 then
      default_pct = remaining / unspecified
    else
      default_pct = 100 / #row_panels
    end
  end

  for i, panel in ipairs(row_panels) do
    local pct = pct_values[i]

    if outer_n and outer_unit then
      if pct then
        widths[i] = format_length_value(outer_n * pct / 100, outer_unit)
      elseif has_percent then
        widths[i] = format_length_value(outer_n * default_pct / 100, outer_unit)
      elseif panel.width and normalize_dimension_for_raw_output(panel.width) then
        widths[i] = panel.width
      else
        widths[i] = nil
      end
    else
      if pct then
        widths[i] = pct .. "%"
      elseif has_percent then
        widths[i] = default_pct .. "%"
      elseif panel.width and normalize_dimension_for_raw_output(panel.width) then
        widths[i] = panel.width
      else
        widths[i] = nil
      end
    end
  end

  return widths
end

local function compute_wordish_row_fractions(row_panels)
  local fracs = {}
  local pct_values = {}
  local has_percent = false
  local specified_sum = 0
  local unspecified = 0

  for i, panel in ipairs(row_panels) do
    local pct = parse_percent_value(panel.width)
    pct_values[i] = pct
    if pct then
      has_percent = true
      specified_sum = specified_sum + pct
    else
      unspecified = unspecified + 1
    end
  end

  local default_pct = 0
  if unspecified > 0 then
    local remaining = 100 - specified_sum
    if remaining > 0 then
      default_pct = remaining / unspecified
    else
      default_pct = 100 / #row_panels
    end
  end

  for i = 1, #row_panels do
    local pct = pct_values[i]
    if pct then
      fracs[i] = pct / 100
    elseif has_percent then
      fracs[i] = default_pct / 100
    else
      fracs[i] = 1 / #row_panels
    end
  end

  return fracs
end

local function make_wordish_cell_blocks(panel, forced_width)
  local blocks = List:new()

  local attrs = copy_attributes(panel.attributes)

  if forced_width then
    attrs["width"] = scale_length_value(forced_width, 0.96)
  elseif panel.width then
    attrs["width"] = panel.width
  else
    attrs["width"] = nil
  end

  if panel.height then
    attrs["height"] = panel.height
  else
    attrs["height"] = nil
  end

  local img = pandoc.Image(
    {},
    panel.src,
    panel.title or "",
    pandoc.Attr(panel.identifier or "", panel.classes or {}, attrs)
  )

  blocks:insert(pandoc.Plain({ img }))

  if panel.caption and panel.caption ~= "" then
    blocks:insert(
      pandoc.Para(
        { pandoc.Str(panel.caption) },
        pandoc.Attr("", {}, { ["custom-style"] = "Caption" })
      )
    )
  end

  return blocks
end

local function build_wordish_table_multipart(div, panels, trailing_blocks)
-- NOTE:
-- Pandoc table cells support only horizontal alignment.
-- DOCX vertical cell alignment (top/center/bottom) cannot be controlled
-- through the Lua table AST here, so multipart div `valign` is ignored
-- for docx/odt fallback.
  local cols = tonumber(clean_attr(get_attr_ci(div, "cols"))) or 2
  local caption = derive_caption(div)
  local outer_width = normalize_dimension_for_raw_output(get_attr_ci(div, "width"))

  local blocks = List:new()
  local resolved = resolve_panels(panels)

  local i = 1
  while i <= #resolved do
    local row_panels = {}
    for j = i, math.min(i + cols - 1, #resolved) do
      table.insert(row_panels, resolved[j])
    end

    local forced_widths = compute_wordish_row_widths(row_panels, outer_width)
    local row_fracs = compute_wordish_row_fractions(row_panels)
    
    local row_cells = List:new()
    
    for k, panel in ipairs(row_panels) do
      row_cells:insert(
        pandoc.Cell(
          make_wordish_cell_blocks(panel, forced_widths[k]),
          pandoc.AlignDefault,
          1,
          1
        )
      )
    end

    while #row_cells < cols do
      row_cells:insert(
        pandoc.Cell(
          { pandoc.Plain({}) },
          pandoc.AlignCenter,
          1,
          1
        )
      )
    end

    local colspecs = {}
    for c = 1, cols do
      local frac = row_fracs[c]
      if frac and frac > 0 then
        colspecs[c] = { pandoc.AlignCenter, frac }
      else
        colspecs[c] = { pandoc.AlignCenter, 0 }
      end
    end
    
    local row = pandoc.Row(row_cells)
    local head = pandoc.TableHead({})
    local foot = pandoc.TableFoot({})
    
    local bodies = {
      {
        attr = pandoc.Attr("", {}, {}),
        row_head_columns = 0,
        head = {},
        body = { row }
      }
    }
    
    blocks:insert(
      pandoc.Table(
        pandoc.Caption(),
        colspecs,
        head,
        bodies,
        foot
      )
    )

    i = i + cols
  end

  if caption and caption ~= "" then
    blocks:insert(caption_para_for_wordish(caption))
  end

  return blocks
end

local function build_simple_fallback_multipart(div, panels, trailing_blocks)
  if is_target_wordish() then
    return build_wordish_table_multipart(div, panels, trailing_blocks)
  end

  local cols = tonumber(clean_attr(get_attr_ci(div, "cols"))) or 2

  local blocks = List:new()
  local resolved = resolve_panels(panels)

  local i = 1
  while i <= #resolved do
    local row_imgs = {}
    local row_caps = {}

    for j = i, math.min(i + cols - 1, #resolved) do
      local panel = resolved[j]
      table.insert(row_imgs, build_resolved_inline_image(panel))
      table.insert(row_caps, panel.caption or "")
    end

    local img_inlines = {}
    for idx, img in ipairs(row_imgs) do
      if idx > 1 then
        table.insert(img_inlines, pandoc.Space())
        table.insert(img_inlines, pandoc.Space())
        table.insert(img_inlines, pandoc.Space())
      end
      table.insert(img_inlines, img)
    end
    blocks:insert(pandoc.Para(img_inlines))

    local has_caption = false
    for _, cap in ipairs(row_caps) do
      if cap ~= "" then
        has_caption = true
        break
      end
    end

    if has_caption then
      local cap_inlines = {}
      for idx, cap in ipairs(row_caps) do
        if idx > 1 then
          table.insert(cap_inlines, pandoc.Space())
          table.insert(cap_inlines, pandoc.Space())
          table.insert(cap_inlines, pandoc.Space())
        end
        table.insert(cap_inlines, pandoc.Str(cap))
      end
      blocks:insert(
        pandoc.Para(
          cap_inlines,
          pandoc.Attr("", {}, { ["custom-style"] = "Caption" })
        )
      )
    end

    i = i + cols
  end

  local caption = derive_caption(div)
  if caption and caption ~= "" then
    blocks:insert(caption_para_for_wordish(caption))
  end

  return blocks
end

local function handle_multipart(div)
  local panels, trailing_blocks = collect_multipart_panels(div)

  if #panels == 0 then
    return div
  end

  if is_target_typst() then
    return build_typst_multipart(div, panels, trailing_blocks)
  elseif is_target_latex() then
    return build_latex_multipart(div, panels, trailing_blocks)
  elseif is_target_wordish() or is_target_ebookish() or is_target_htmlish() then
    return build_simple_fallback_multipart(div, panels, trailing_blocks)
  end

  return build_simple_fallback_multipart(div, panels, trailing_blocks)
end

-- ------------------------------------------------------------
-- Equation block
-- ------------------------------------------------------------

local function handle_equationblock(div)
  local align = clean_attr(get_attr_ci(div, "align"))
  local numbered = parse_bool(get_attr_ci(div, "numbered"), true)
  local label = get_identifier(div)

  if not is_target_typst() then
    return div
  end

  local body_typst = pandoc_blocks_to_typst(div.content)
  if body_typst == "" then
    return div
  end

  local out = {}

  if align == "center" or align == nil then
    table.insert(out, body_typst)
  elseif align == "left" then
    table.insert(out, "#align(left)[")
    table.insert(out, body_typst)
    table.insert(out, "]")
  elseif align == "right" then
    table.insert(out, "#align(right)[")
    table.insert(out, body_typst)
    table.insert(out, "]")
  else
    table.insert(out, body_typst)
  end

  local joined = table.concat(out, "\n")

  if label and numbered then
    joined = joined .. " <" .. label .. ">"
  end

  return pandoc.RawBlock("typst", joined)
end

-- ------------------------------------------------------------
-- Code blocks
-- ------------------------------------------------------------

local function build_typst_codeblock(el)
  local caption = clean_attr(get_attr_ci(el, "caption"))
  local label = get_identifier(el)
  local numbered = parse_bool(get_attr_ci(el, "numbered"), true)
  local linenos = parse_bool(get_attr_ci(el, "linenos"), false)
  local language = nil

  if el.classes and #el.classes > 0 then
    language = el.classes[1]
  else
    local classes = get_classes(el)
    if #classes > 0 then
      language = classes[1]
    end
  end

  language = clean_attr(language) or clean_attr(get_attr_ci(el, "language")) or "text"

  local code = el.text or ""
  code = code:gsub("\\", "\\\\")
  code = code:gsub("`", "\\`")

  local raw_opts = {
    'block: true',
    'lang: "' .. escape_typst_string(language) .. '"'
  }

  if linenos then
    table.insert(raw_opts, 'numbering: "1."')
  end

  local out = {}
  table.insert(out, "#figure(")

  if caption and caption ~= "" then
    table.insert(out, "  caption: [" .. escape_typst_content(caption) .. "],")
  end

  table.insert(out, "  [#raw(" .. table.concat(raw_opts, ", ") .. ", `" .. code .. "`)]")

  if label and numbered then
    table.insert(out, ") <" .. label .. ">")
  else
    table.insert(out, ")")
  end

  return pandoc.RawBlock("typst", table.concat(out, "\n"))
end

local function build_latex_codeblock(el)
  local caption = clean_attr(get_attr_ci(el, "caption"))
  if not caption or caption == "" then
    return nil
  end

  local code = el.text or ""
  local out = {}
  table.insert(out, "\\begin{figure}[htbp]")
  table.insert(out, "\\caption{" .. escape_latex(caption) .. "}")
  table.insert(out, "\\begin{verbatim}")
  table.insert(out, code)
  table.insert(out, "\\end{verbatim}")
  table.insert(out, "\\end{figure}")

  return pandoc.RawBlock("latex", table.concat(out, "\n"))
end

function CodeBlock(el)
  local caption = clean_attr(get_attr_ci(el, "caption"))

  if not caption then
    return el
  end

  if is_target_typst() then
    return build_typst_codeblock(el)
  elseif is_target_latex() then
    local raw = build_latex_codeblock(el)
    return raw or el
  end

  return el
end

function Div(el)
  if has_class(el, "multipart") then
    return handle_multipart(el)
  elseif has_class(el, "equationblock") then
    return handle_equationblock(el)
  end

  return el
end

function Pandoc(doc)
  local json = pandoc.write(doc, "json")
  local file = io.open("_ast_section.json", "w")
  if file then
    file:write(json)
    file:close()
  end
  return doc
end