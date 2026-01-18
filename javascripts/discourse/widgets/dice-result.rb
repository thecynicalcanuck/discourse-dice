# frozen_string_literal: true

# name: discourse-dice
# about: Server-side deterministic dice roller for Discourse, compatible with the new Glimmer post stream.
# version: 1.0.0
# authors: Your Name / Adapted for server-side rendering
# url: https://your-repo-if-any

# This plugin fully replaces the deprecated client-side widget/glue system.
# Users write: [wrap=dice crit="6,1"]2d6+3t8i[/wrap]
# Core Discourse renders it as <div class="d-wrap" data-wrap="dice" data-crit="6,1">2d6+3t8i</div>
# This plugin replaces those placeholders server-side with the final rendered dice roll.

MAX_DICE_QUANTITY = 100
MAX_DICE_FACES = 1_000_000 # Reasonable limit; original likely capped at ~67M (2^26)

ERROR_MESSAGES = {
  "dice.invalid.generic" => "Invalid dice expression",
  "dice.missing.faces" => "Missing number of faces (e.g., d6)",
  "dice.invalid.faces" => "Number of faces must be greater than 1",
  "dice.excessive.faces" => "Too many faces (max #{MAX_DICE_FACES})",
  "dice.invalid.quantity" => "Quantity must be positive",
  "dice.excessive.quantity" => "Too many dice (max #{MAX_DICE_QUANTITY})",
  "dice.invalid.modifier" => "Modifier must be positive",
  "dice.invalid.threshold" => "Threshold must be positive",
  "dice.invalid.crits" => "Invalid critical values list",
  "dice.invalid.halt_after_error" => "Halted: previous dice roll in this post had an error",
}.freeze

DICE_REGEXP = /(\d+)?d(\d+)?(?:([+-])(\d+))?(?:t(\d+))?(i)?/.freeze

# Standard Mersenne Twister 19937 implementation in Ruby
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

# Exact port of the provided MurmurHash3 x86_32 implementation
module MurmurHash3
  def self.x86_32(key, seed = 0)
    data = key.bytes
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

def parse_dice(match, raw_input)
  errors = []
  errors << "dice.invalid.generic" if match.nil?

  quantity = match[1] ? match[1].to_i : 1
  faces = match[2]&.to_i
  mod_sign = match[3]
  mod_val = match[4]&.to_i
  threshold = match[5]&.to_i
  individual = match[6] == "i"

  errors << "dice.invalid.quantity" if quantity <= 0
  errors << "dice.excessive.quantity" if quantity > MAX_DICE_QUANTITY

  if faces.nil?
    errors << "dice.missing.faces"
  elsif faces <= 1
    errors << "dice.invalid.faces"
  elsif faces > MAX_DICE_FACES
    errors << "dice.excessive.faces"
  end

  mod_value = nil
  if mod_val
    if mod_val <= 0
      errors << "dice.invalid.modifier"
    else
      mod_value = mod_sign == "-" ? -mod_val : mod_val
    end
  end

  errors << "dice.invalid.threshold" if threshold && threshold <= 0

  {
    errors: errors,
    quantity: quantity,
    faces: faces,
    mod_value: mod_value,
    threshold: threshold,
    individual: individual,
    raw_input: raw_input || match&.[0],
    raw_results: nil,
    crits: nil
  }
end

def parse_crits(crit_str, attrs)
  return attrs if crit_str.blank?

  crits = crit_str.split(",").map { |s| Integer(s.strip) rescue nil }
  if crits.any?(&:nil?)
    attrs[:errors] << "dice.invalid.crits"
  else
    attrs[:crits] = crits
  end
  attrs
end

def bounded_rand(mt, max_val)
  # Rejection sampling for zero bias (negligible overhead for typical dice)
  return 0 if max_val <= 1
  limit = 0xFFFFFFFF - (0xFFFFFFFF % max_val)
  loop do
    r = mt.extract_number
    return r % max_val if r <= limit
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
    mod_class = attrs[:mod_value] > 0 ? "dice-mod-pos" : "dice-mod-neg"
    mod_text = attrs[:mod_value] > 0 ? "+#{attrs[:mod_value]}" : attrs[:mod_value].to_s
    parts << "<span class=\"dice-input dice-mod #{mod_class}\">#{mod_text}</span>"
  end

  if attrs[:threshold]
    parts << "<span class=\"dice-input dice-threshold-txt\">t</span>"
    parts << "<span class=\"dice-input dice-threshold\">#{attrs[:threshold]}</span>"
  end

  parts << "<span class=\"dice-input dice-individual-txt\">i</span>" if attrs[:individual]

  "<span class=\"dice-input\">#{parts.join}</span>"
end

def render_dice_results(attrs)
  joiner = attrs[:individual] ? ", " : "<span class=\"dice-join-plus\">+</span>"

  total_sum = attrs[:raw_results].sum + (attrs[:mod_value] || 0)
  num_success = 0
  threshold_class = ""

  unless attrs[:individual]
    if attrs[:threshold]
      threshold_class = total_sum >= attrs[:threshold] ? "threshold-pass" : "threshold-fail"
    end
  end

  results_html = attrs[:raw_results].map.with_index do |die, idx|
    die_class = "die"
    die_class += " dice-crit crit-#{die}" if attrs[:crits]&.include?(die)

    if attrs[:individual] && attrs[:threshold]
      val = die + (attrs[:mod_value] || 0)
      pass_class = val >= attrs[:threshold] ? "threshold-ipass" : "threshold-ifail"
      die_class += " #{pass_class}"
      num_success += 1 if val >= attrs[:threshold]
    end

    content = die.to_s
    idx.zero? ? "<span class=\"#{die_class}\">#{content}</span>" : "#{joiner}<span class=\"#{die_class}\">#{content}</span>"
  end.join

  unless attrs[:individual]
    show_total = attrs[:quantity] > 1 || attrs[:mod_value]&.nonzero?

    if attrs[:mod_value]&.nonzero?
      sym = attrs[:mod_value] > 0 ? " +" : " -"
      val = attrs[:mod_value].abs
      results_html += "<span class=\"dice-mod-sym sym-#{attrs[:mod_value] > 0 ? 'plus' : 'minus'}\">#{sym}</span><span class=\"dice-mod\">#{val}</span>"
      show_total = true
    end

    if show_total
      results_html += "<span class=\"dice-sum-sep\"> = </span><span class=\"dice-sum\">#{total_sum}</span>"
    end
  else
    if attrs[:threshold] && attrs[:quantity] > 1
      success_text = "#{num_success} success#{num_success == 1 ? '' : 'es'}"
      results_html += "<span class=\"dice-numpass-sep\"> </span><span class=\"dice-numpass\">#{success_text}</span>"
    end
  end

  "<div class=\"dice-results #{threshold_class}\">#{results_html}</div>"
end

def render_dice_roll(attrs)
  if attrs[:errors].any?
    warning = "⚠️"
    errors_html = attrs[:errors].map do |e|
      msg = ERROR_MESSAGES[e] || e
      msg += " in '#{attrs[:raw_input]}'" if attrs[:raw_input]
      "<div class=\"dice-err-input\">#{warning} <span class=\"dice-err-msg\">#{msg}</span></div>"
    end.join
    return errors_html
  end

  die_emoji = "🎲"
  input_html = "<div class=\"dice-input-explain\">#{die_emoji} #{render_dice_input(attrs)}</div>"
  results_html = attrs[:raw_results] ? render_dice_results(attrs) : ""

  "<blockquote class=\"dice-result\">#{input_html}#{results_html}</blockquote>"
end

after_initialize do
  module DiscourseDiceServerRenderer
    def self.cook(raw, opts = {})
      cooked = super(raw, opts)

      post = opts[:post]
      return cooked unless post && cooked.include?('data-wrap="dice"')

      fragment = Nokogiri::HTML::DocumentFragment.parse(cooked)
      placeholders = fragment.css('.d-wrap[data-wrap="dice"]')
      return cooked if placeholders.empty?

      seed_str = "#{post.id} #{post.created_at.iso8601}"
      seed = MurmurHash3.x86_32(seed_str, 843031067)
      mt = MersenneTwister19937.new(seed)

      seen_errors = false

      placeholders.each do |elem|
        expression = elem.text.strip
        crit_str = elem['data-crit']

        match = DICE_REGEXP.match(expression)
        attrs = parse_dice(match, expression)
        parse_crits(crit_str, attrs)

        if seen_errors && attrs[:errors].empty?
          attrs[:errors] << "dice.invalid.halt_after_error"
        end

        seen_errors = true if attrs[:errors].any?

        roll_dice(mt, attrs) unless attrs[:errors].any?

        new_html = render_dice_roll(attrs)
        replacement = Nokogiri::HTML.fragment(new_html)
        elem.replace(replacement)
      end

      fragment.to_html
    end
  end

  PrettyText.singleton_class.prepend DiscourseDiceServerRenderer
end
