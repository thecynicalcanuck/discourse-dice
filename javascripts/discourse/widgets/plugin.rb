# frozen_string_literal: true

# name: discourse-dice-server
# about: Server-side deterministic dice roller for Discourse (Glimmer-compatible replacement for deprecated widgets)
# version: 1.2.1
# authors: Community / Adapted for server-side
# url: https://github.com/your-repo-if-any

require 'nokogiri'

SEED_CONSTANT = 843031067
MAX_QUANTITY = 100
MAX_FACES = 1_000_000

class MersenneTwister19937
  N = 624
  M = 397
  MATRIX_A = 0x9908b0df
  UPPER_MASK = 0x80000000
  LOWER_MASK = 0x7fffffff

  def initialize(seed)
    @mt = Array.new(N)
    @mt[0] = seed & 0xffffffff
    (1...N).each do |i|
      @mt[i] = (0x6c078965 * (@mt[i-1] ^ (@mt[i-1] >> 30)) + i) & 0xffffffff
    end
    @index = N
  end

  def extract_number
    twist if @index >= N

    y = @mt[@index]
    @index += 1

    y ^= (y >> 11)
    y ^= (y << 7) & 0x9d2c5680
    y ^= (y << 15) & 0xefc60000
    y ^= (y >> 18)

    y
  end

  private

  def twist
    (0...N).each do |i|
      x = (@mt[i] & UPPER_MASK) | (@mt[(i + 1) % N] & LOWER_MASK)
      x_a = x >> 1
      x_a ^= MATRIX_A if x.odd?
      @mt[i] = @mt[(i + M) % N] ^ x_a
    end
    @index = 0
  end
end

module MurmurHash3
  def self.x86_32(key, seed = 0)
    data = key.encode('ASCII').bytes
    length = data.length
    h = seed ^ length

    i = 0
    while i + 4 <= length
      k = data[i] |
          (data[i + 1] << 8) |
          (data[i + 2] << 16) |
          (data[i + 3] << 24)

      k = (k * 0xcc9e2d51) & 0xffffffff
      k = ((k << 15) | (k >> 17)) & 0xffffffff
      k = (k * 0x1b873593) & 0xffffffff

      h ^= k
      h = ((h << 13) | (h >> 19)) & 0xffffffff
      h = (h * 5 + 0xe6546b64) & 0xffffffff

      i += 4
    end

    k = 0
    tail = length - i
    k ^= data[i + 2] << 16 if tail >= 3
    k ^= data[i + 1] << 8 if tail >= 2
    k ^= data[i] if tail >= 1

    if tail >= 1
      k = (k * 0xcc9e2d51) & 0xffffffff
      k = ((k << 15) | (k >> 17)) & 0xffffffff
      k = (k * 0x1b873593) & 0xffffffff
      h ^= k
    end

    h ^= length
    h ^= h >> 16
    h = (h * 0x85ebca6b) & 0xffffffff
    h ^= h >> 13
    h = (h * 0xc2b2ae35) & 0xffffffff
    h ^= h >> 16

    h
  end
end

DICE_REGEXP = /(\d+)?d(\d+)?(?:([+-])(\d+))?(?:t(\d+))?(i)?/.freeze

def parse_dice(match, expression)
  errors = []
  errors << "Invalid dice expression" if match.nil?

  quantity = match[1] ? match[1].to_i : 1
  faces = match[2]&.to_i
  mod_sign = match[3]
  mod_val = match[4]&.to_i
  threshold = match[5]&.to_i
  individual = !match[6].nil?

  errors << "Quantity must be positive" if quantity <= 0
  errors << "Too many dice (max #{MAX_QUANTITY})" if quantity > MAX_QUANTITY

  if faces.nil?
    errors << "Missing number of faces"
  elsif faces <= 1
    errors << "Faces must be > 1"
  elsif faces > MAX_FACES
    errors << "Too many faces"
  end

  mod_value = nil
  if mod_val
    if mod_val <= 0
      errors << "Modifier must be positive"
    else
      mod_value = mod_sign == "-" ? -mod_val : mod_val
    end
  end

  errors << "Threshold must be positive" if threshold && threshold <= 0

  {
    errors: errors,
    quantity: quantity,
    faces: faces,
    mod_value: mod_value,
    threshold: threshold,
    individual: individual,
    raw_input: expression,
    raw_results: nil,
    crits: []
  }
end

def parse_crits(crit_str, attrs)
  return attrs if crit_str.blank?

  crits = crit_str.split(",").map { |s| Integer(s.strip) rescue nil }
  if crits.any?(&:nil?)
    attrs[:errors] << "Invalid critical values"
  else
    attrs[:crits] = crits
  end
  attrs
end

def bounded_rand(mt, max_val)
  return 0 if max_val <= 1
  limit = (0xFFFFFFFF / max_val) * max_val
  loop do
    r = mt.extract_number
    return r % max_val if r < limit
  end
end

def roll_dice(mt, attrs)
  return if attrs[:errors].any?

  results = []
  attrs[:quantity].times do
    results << 1 + bounded_rand(mt, attrs[:faces])
  end
  attrs[:raw_results] = results
end

def render_dice_input(attrs)
  parts = []
  parts << "<span class=\"dice-input dice-quantity\">#{attrs[:quantity]}</span>"
  parts << "d"
  parts << "<span class=\"dice-input dice-faces\">#{attrs[:faces]}</span>"

  if attrs[:mod_value]&.nonzero?
    text = attrs[:mod_value] > 0 ? "+#{attrs[:mod_value]}" : attrs[:mod_value]
    cls = attrs[:mod_value] > 0 ? "dice-mod-pos" : "dice-mod-neg"
    parts << "<span class=\"dice-input dice-mod #{cls}\">#{text}</span>"
  end

  if attrs[:threshold]
    parts << "<span class=\"dice-input dice-threshold-txt\">t</span>"
    parts << "<span class=\"dice-input dice-threshold\">#{attrs[:threshold]}</span>"
  end

  if attrs[:individual]
    parts << "<span class=\"dice-input dice-individual-txt\">i</span>"
  end

  "<span class=\"dice-input\">#{parts.join}</span>"
end

def render_dice_results(attrs)
  joiner = attrs[:individual] ? ", " : "<span class=\"dice-join-plus\">+</span>"

  total = attrs[:raw_results].sum + (attrs[:mod_value] || 0)
  success_count = 0
  threshold_class = ""

  unless attrs[:individual]
    threshold_class = " threshold-pass" if attrs[:threshold] && total >= attrs[:threshold]
    threshold_class = " threshold-fail" if attrs[:threshold] && total < attrs[:threshold]
  end

  results_html = attrs[:raw_results].map.with_index do |die, i|
    cls = "die"
    cls += " dice-crit crit-#{die}" if attrs[:crits].include?(die)

    if attrs[:individual] && attrs[:threshold]
      val = die + (attrs[:mod_value] || 0)
      cls += val >= attrs[:threshold] ? " threshold-ipass" : " threshold-ifail"
      success_count += 1 if val >= attrs[:threshold]
    end

    die_html = "<span class=\"#{cls}\">#{die}</span>"
    i.zero? ? die_html : "#{joiner}#{die_html}"
  end.join

  unless attrs[:individual]
    if attrs[:mod_value]&.nonzero? || attrs[:quantity] > 1
      if attrs[:mod_value]&.nonzero?
        sym = attrs[:mod_value] > 0 ? " +" : " -"
        val = attrs[:mod_value].abs
        results_html += "<span class=\"dice-mod-sym sym-#{attrs[:mod_value] > 0 ? 'plus' : 'minus'}\">#{sym}</span><span class=\"dice-mod\">#{val}</span>"
      end
      results_html += "<span class=\"dice-sum-sep\"> = </span><span class=\"dice-sum\">#{total}</span>"
    end
  else
    if attrs[:threshold] && attrs[:quantity] > 1
      plural = success_count == 1 ? "success" : "successes"
      results_html += "<span class=\"dice-numpass-sep\"> </span><span class=\"dice-numpass\">#{success_count} #{plural}</span>"
    end
  end

  "<div class=\"dice-results#{threshold_class}\">#{results_html}</div>"
end

def render_dice_roll(attrs)
  if attrs[:errors].any?
    warning = "⚠️"
    errors_html = attrs[:errors].map do |e|
      "<div class=\"dice-err-input\">#{warning} <span class=\"dice-err-msg\">#{e} (#{attrs[:raw_input]})</span></div>"
    end.join
    return errors_html
  end

  input_html = "<div class=\"dice-input-explain\">🎲 #{render_dice_input(attrs)}</div>"
  results_html = attrs[:raw_results] ? render_dice_results(attrs) : ""

  "<blockquote class=\"dice-result\">#{input_html}#{results_html}</blockquote>"
end

after_initialize do
  module ::DiscourseDice
    module Cooker
      def cook(raw, opts = {})
        cooked = super(raw, opts)

        return cooked unless cooked.include?('data-wrap="dice"')

        doc = Nokogiri::HTML::DocumentFragment.parse(cooked)
        placeholders = doc.css('div.d-wrap[data-wrap="dice"]')
        return cooked if placeholders.empty?

        post = opts[:post]
        mt = nil
        seen_error = false

        if post
          seed_string = "#{post.id} #{post.created_at.iso8601}"
          seed = MurmurHash3.x86_32(seed_string, SEED_CONSTANT)
          mt = MersenneTwister19937.new(seed)
        end

        placeholders.each do |placeholder|
          expression = placeholder.content.strip
          crit_str = placeholder['data-crit']

          match = DICE_REGEXP.match(expression)
          attrs = parse_dice(match, expression)
          attrs = parse_crits(crit_str, attrs)

          if mt
            if seen_error && attrs[:errors].empty?
              attrs[:errors] << "Halted due to previous error in post"
            end

            roll_dice(mt, attrs) if attrs[:errors].empty?

            seen_error = true if attrs[:errors].any?
          end

          new_html = render_dice_roll(attrs)
          new_fragment = Nokogiri::HTML.fragment(new_html)
          placeholder.replace(new_fragment)
        end

        doc.to_html
      end
    end
  end

  PrettyText.singleton_class.prepend ::DiscourseDice::Cooker
end
