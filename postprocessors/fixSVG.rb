#!/usr/bin/env ruby
# frozen_string_literal: true
#encoding: utf-8
# Generic Mermaid SVG layer-order fixer for Pandocomatic/Scrivomatic postprocessing.
# Reads SVG from STDIN, reorders each container (<g> / <svg>)
# so any text or label groups are moved after shapes, then writes to STDOUT.

require "nokogiri"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

svg_data = $stdin.read
doc = Nokogiri::XML(svg_data) { |c| c.default_xml.noblanks }
root = doc.root

unless root&.name == "svg"
  warn "fix_mermaid_svg.rb: input is not an SVG — passing through unchanged."
  puts svg_data
  exit 0
end

SVG_NS = "http://www.w3.org/2000/svg"
SKIP   = %w[defs clipPath mask filter marker pattern linearGradient radialGradient]
TEXTY_HINTS = %w[label nodeLabel edgeLabel title caption]

def svg?(n) = n.respond_to?(:name) && n.namespace&.href == SVG_NS
def container?(n) = svg?(n) && (n.name == "svg" || n.name == "g")
def skip?(n) = svg?(n) && SKIP.include?(n.name)

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

traverse_and_fix(root)
puts doc.to_xml
