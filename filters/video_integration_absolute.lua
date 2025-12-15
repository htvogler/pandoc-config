#!/usr/bin/env lua
--[[
video_integration.lua
... (KEEP YOUR HEADER EXACTLY AS-IS)
]]

local path_sep = package.config:sub(1,1)

local function dirname(p)
  if not p or p == "" then return "." end
  local d = p:match("^(.*)[/\\]")
  return d and d ~= "" and d or "."
end

local function join(a, b)
  if a:sub(-1) == "/" or a:sub(-1) == "\\" then return a .. b end
  return a .. path_sep .. b
end

local function ensure_parent_dirs(filepath)
  local dir = dirname(filepath)
  local parts = {}
  for part in dir:gmatch("[^/\\]+") do parts[#parts+1] = part end
  local cur = dir:match("^[/\\]") and path_sep or ""
  for i = 1, #parts do
    cur = (cur == "" and parts[i]) or join(cur, parts[i])
    pandoc.system.make_directory(cur, true) -- parents ok
  end
end

-- Pandoc 3.x compatibility: file existence check
local function file_exists(path)
  if pandoc.system and pandoc.system.path and pandoc.system.path.exists then
    return pandoc.system.path.exists(path)
  end
  if pandoc.system and pandoc.system.exists then
    return pandoc.system.exists(path)
  end
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end

-- Pandoc 3.x compatibility: copy file
local function copy_file(src, dst)
  if pandoc.system and pandoc.system.copy_file then
    return pandoc.system.copy_file(src, dst)
  end
  if pandoc.system and pandoc.system.copyfile then
    return pandoc.system.copyfile(src, dst)
  end

  -- Fallback: macOS/Linux cp
  local function q(s)
    s = tostring(s)
    s = s:gsub('"', '\\"')
    return '"' .. s .. '"'
  end
  local cmd = "/bin/cp -p " .. q(src) .. " " .. q(dst)
  local ok = os.execute(cmd)
  return ok
end

local function to_file_url(path)
  if not path:match("^/") then
    path = "/" .. path
  end
  path = path:gsub("%%", "%%25")
             :gsub(" ", "%%20")
             :gsub("#", "%%23")
             :gsub("%?", "%%3F")
  return "file://" .. path
end

-- IMPORTANT: Scrivomatic runs pandoc with a real working directory.
-- Pandoc may report input/output files as relative paths, so we fall back to $PWD.
local function workdir()
  return os.getenv("PWD") or "."
end

local function base_dir_for_links()
  local out = (PANDOC_STATE and PANDOC_STATE.output_file) or ""
  if out ~= "" and out ~= "-" then
    local d = dirname(out)
    if d ~= "." then return d end
    return workdir()
  end

  if PANDOC_STATE and PANDOC_STATE.input_files and #PANDOC_STATE.input_files > 0 then
    local inp = PANDOC_STATE.input_files[1]
    local d = dirname(inp)
    if d ~= "." then return d end
    return workdir()
  end

  return workdir()
end

-- Configure where your “master” videos live (stable, never overwritten)
local VIDEO_STORE = "/Users/htv/Downloads"

local function video_store()
  return os.getenv("VIDEO_STORE") or VIDEO_STORE
end

local function copy_from_store(rel_src)
  local store = video_store()
  if not store or store == "" or store == "VIDEO_STORE_NOT_SET" then
    return
  end

  local outdir = base_dir_for_links()

  local src_abs = join(store, rel_src)
  local dst_abs = join(outdir, rel_src)

  if not file_exists(src_abs) then
    io.stderr:write("[video] missing: " .. src_abs .. "\n")
    return
  end

  if file_exists(dst_abs) then
    return
  end

  ensure_parent_dirs(dst_abs)
  copy_file(src_abs, dst_abs)
end

local function parse_kv_lines(text)
  local kv = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local k, v = line:match("^%s*([%w_-]+)%s*:%s*(.-)%s*$")
    if k and v and v ~= "" then
      kv[k] = v
    end
  end
  return kv
end

local function link_blocks(src, caption)
  caption = (caption and caption ~= "") and caption or "Video"

  local outdir = base_dir_for_links()
  local abs_path = join(outdir, src)
  local target = to_file_url(abs_path)

  return {
    pandoc.Para({
      pandoc.Str("▶"),
      pandoc.Space(),
      pandoc.Link(caption, target),
    })
  }
end

local function render_video(src, caption)
  if FORMAT:match("html") then
    copy_from_store(src)
  end

  if FORMAT:match("html") or FORMAT:match("epub") then
    local html = string.format([[
<video controls preload="metadata">
  <source src="%s" type="video/mp4">
  <a href="%s">%s</a>
</video>]],
      src, src, caption
    )
    return pandoc.RawBlock("html", html)
  end

  return link_blocks(src, caption)
end

function CodeBlock(cb)
  if not cb.classes:includes("video") then return nil end
  local kv = parse_kv_lines(cb.text)
  local src = kv.src or ""
  local caption = kv.caption or "Video"
  if src == "" then return nil end
  return render_video(src, caption)
end

function Div(div)
  if not div.classes:includes("video") then return nil end

  local lines = {}
  for _, b in ipairs(div.content) do
    lines[#lines+1] = pandoc.utils.stringify(b)
  end
  local kv = parse_kv_lines(table.concat(lines, "\n"))

  local src = kv.src or ""
  local caption = kv.caption or "Video"
  if src == "" then return nil end

  return render_video(src, caption)
end
