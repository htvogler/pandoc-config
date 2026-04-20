#!/usr/bin/env ruby
# frozen_string_literal: true
# encoding: utf-8
# fixSVG.rb — SVG layer-order fixer for Pandocomatic/Scrivomatic postprocessing.
# Reads Typst content from STDIN, finds all image("*.svg") references,
# and reorders each SVG file so connectors and text appear correctly.
# Uses Nokogiri for proper XML parsing. Writes Typst content to STDOUT unchanged
# (SVG files are modified in place).
#
# Handles two engines:
#   Mermaid: moves <g class="clusters"> before <g class="edgePaths"> so
#            subgraph boxes don't paint over connector lines.
#   D2:      moves connection <g>s (identified by child path[class*="connection"])
#            to after the last shape group, so connectors appear on top.
#   Both:    promotes text/label groups to top of each container (existing logic).
#
# NOTE: Uses at_css/css instead of at_xpath with namespace declarations because
#       SVG child elements inherit the namespace rather than declaring it explicitly,
#       which causes XPath namespace matching to silently miss them in Nokogiri.
# NOTE: Uses element_children instead of children throughout to avoid text/whitespace
#       nodes interfering with index comparisons and selects.

require "nokogiri"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

SVG_NS      = "http://www.w3.org/2000/svg"
SKIP        = %w[defs clipPath mask filter marker pattern linearGradient radialGradient]
TEXTY_HINTS = %w[label nodeLabel edgeLabel title caption]

def svg?(n)       = n.respond_to?(:name) && n.namespace&.href == SVG_NS
def container?(n) = svg?(n) && (n.name == "svg" || n.name == "g")
def skip?(n)      = svg?(n) && SKIP.include?(n.name)

def looks_texty?(n)
  return false unless svg?(n)
  return true if n.name == "text" || n.name == "tspan"
  cls = n["class"].to_s
  return true if TEXTY_HINTS.any? { |h| cls.include?(h) }
  !n.xpath(".//svg:text", "svg" => SVG_NS).empty?
end

def reorder_children!(node)
  kids = node.element_children
  return if kids.size < 2
  non_texty, texty = kids.partition { |c| !looks_texty?(c) }
  kids.each(&:remove)
  non_texty.each { |c| node.add_child(c) }
  texty.each     { |c| node.add_child(c) }
end

def traverse_and_fix(node)
  return unless svg?(node)
  return if skip?(node)
  reorder_children!(node) if container?(node)
  node.element_children.each { |ch| traverse_and_fix(ch) unless skip?(ch) }
end

# --- Engine detection ---
# D2: outer <svg> has data-d2-version; inner <svg> has class containing "d2-svg".
# Mermaid: root <svg> has class="flowchart" or id="my-svg", always has g.edgePaths.
def detect_engine(root)
  return :mermaid if root["class"].to_s.include?("flowchart")
  return :mermaid if root["id"].to_s == "my-svg"
  return :mermaid if root.at_css("g.edgePaths")
  return :d2 if root["class"].to_s.include?("d2-svg") || root.at_css('[class~="d2-svg"]')
  :unknown
end

# --- Mermaid fix ---
# Mermaid renders: edgePaths → clusters → edgeLabels → nodes
# Clusters (subgraph boxes) paint over edgePaths (connectors).
# Fix: move clusters before edgePaths so paint order becomes:
#   clusters → edgePaths → edgeLabels → nodes
def fix_mermaid_layer_order(root)
  search_in = root.at_css("g.root") || root

  edge_paths = search_in.element_children.find { |n| n["class"]&.include?("edgePaths") }
  clusters   = search_in.element_children.find { |n| n["class"]&.include?("clusters") }
  return unless edge_paths && clusters

  kids   = search_in.element_children.to_a
  ep_idx = kids.index(edge_paths)
  cl_idx = kids.index(clusters)
  return if cl_idx < ep_idx

  clusters.remove
  edge_paths.add_previous_sibling(clusters)
end

# --- D2 fix ---
# D2 connection groups are direct children of the inner d2-svg <svg>.
# Each connection group is a <g> whose child is a <path class="connection ...">.
# Shape groups are <g> elements containing a <g class="shape"> child.
# Fix: move all connection groups to after the last shape group.
def fix_d2_layer_order(root)
  d2_root = root["class"].to_s.include?("d2-svg") ? root : (root.at_css('[class~="d2-svg"]') || root)

  connections = d2_root.element_children.select { |n|
    n.name == "g" && n.at_css('path[class*="connection"]')
  }
  return if connections.empty?

  last_shape_group = d2_root.element_children.to_a.reverse.find { |n|
    n.name == "g" && n.at_css("g.shape")
  }
  return unless last_shape_group

  connections.each(&:remove)
   connections.each { |c|
     c.css('path[mask]').each { |p| p.remove_attribute('mask') }
     last_shape_group.add_next_sibling(c)
   }
end

def fix_svg_file(path)
  return unless File.exist?(path)
  raw = File.read(path, encoding: "UTF-8")
  doc = Nokogiri::XML(raw) { |c| c.default_xml.noblanks }
  root = doc.root
  unless root&.name == "svg"
    warn "fixSVG.rb: #{path} is not an SVG — skipping."
    return
  end

  engine = detect_engine(root)

  # Run text/label promotion FIRST, then engine-specific layer reordering
  # (reversed order: traverse_and_fix would undo the reordering if run after)
  traverse_and_fix(root)

  case engine
  when :mermaid
    fix_mermaid_layer_order(root)
  when :d2
    fix_d2_layer_order(root)
  end

  File.write(path, doc.to_xml, encoding: "UTF-8")
  warn "fixSVG.rb: reordered layers in #{path} (#{engine})"
rescue => e
  warn "fixSVG.rb: error processing #{path}: #{e.message}"
end

# Read typst content from stdin
typst_content = $stdin.read

# Find all image("*.svg") references and process each file
seen = {}
typst_content.scan(/image\(\s*"([^"]+\.svg)"\s*\)/) do |match|
  svg_path = match[0]
  next if seen[svg_path]
  seen[svg_path] = true
  fix_svg_file(svg_path)
end

# Pass typst content through unchanged
puts typst_content
