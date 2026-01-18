def render_dice_input(attrs)
  parts = []
  parts << "<span class=\"dice-input dice-quantity\">#{attrs[:quantity]}</span>"
  parts << "d"
  parts << "<span class=\"dice-input dice-faces\">#{attrs[:faces]}</span>"

  if attrs[:mod_value].present? && attrs[:mod_value] != 0
    if attrs[:mod_value] > 0
      parts << "<span class=\"dice-input dice-mod dice-mod-pos\">+#{attrs[:mod_value]}</span>"
    else
      parts << "<span class=\"dice-input dice-mod dice-mod-neg\">#{attrs[:mod_value]}</span>"
    end
  end

  if attrs[:threshold].present?
    parts << "<span class=\"dice-input dice-threshold-txt\">t</span>"
    parts << "<span class=\"dice-input dice-threshold\">#{attrs[:threshold]}</span>"
  end

  if attrs[:individual]
    parts << "<span class=\"dice-input dice-individual-txt\">i</span>"
  end

  parts.join
end

def render_dice_results(attrs)
  joiner = attrs[:individual] ? ", " : "<span class=\"dice-join-plus\">+</span>"

  total_sum = attrs[:raw_results].sum + (attrs[:mod_value] || 0)
  num_success = 0
  threshold_class = ""

  if attrs[:threshold] && !attrs[:individual]
    threshold_class = total_sum >= attrs[:threshold] ? "threshold-pass" : "threshold-fail"
  end

  results_parts = attrs[:raw_results].map.with_index do |die, idx|
    die_class = "die"
    die_class += " dice-crit crit-#{die}" if attrs[:crits]&.include?(die)

    if attrs[:individual]
      val = die + (attrs[:mod_value] || 0)
      if attrs[:threshold]
        pass_fail = val >= attrs[:threshold] ? "threshold-ipass" : "threshold-ifail"
        die_class += " #{pass_fail}"
        num_success += 1 if val >= attrs[:threshold]
      end
    end

    inner = die.to_s
    idx == 0 ? "<span class=\"#{die_class}\">#{inner}</span>" : "#{joiner}<span class=\"#{die_class}\">#{inner}</span>"
  end.join

  # Add modifier and total if needed
  if !attrs[:individual]
    show_total = false

    if attrs[:mod_value].present? && attrs[:mod_value] != 0
      show_total = true
      if attrs[:mod_value] > 0
        results_parts += "<span class=\"dice-mod-sym sym-plus\"> +</span><span class=\"dice-mod\">#{attrs[:mod_value]}</span>"
      else
        results_parts += "<span class=\"dice-mod-sym sym-minus\"> -</span><span class=\"dice-mod\">#{attrs[:mod_value].abs}</span>"
      end
    end

    show_total = true if attrs[:quantity] > 1
    if show_total
      results_parts += "<span class=\"dice-sum-sep\"> = </span><span class=\"dice-sum\">#{total_sum}</span>"
    end
  else
    if attrs[:threshold] && attrs[:quantity] > 1
      success_text = I18n.t("#{theme_prefix}.dice.result.success_count", count: num_success)
      results_parts += "<span class=\"dice-numpass-sep\"> </span><span class=\"dice-numpass\">#{success_text}</span>"
    end
  end

  "<div class=\"dice-results #{threshold_class}\">#{results_parts}</div>"
end

# Main rendering method (call this in your cooker)
def render_dice_roll(attrs)
  if attrs[:errors].present? && attrs[:errors].any?
    warning_emoji = "⚠️"  # :warning:
    errors_html = attrs[:errors].map do |e|
      i18n_attrs = { input: attrs[:raw_input] }
      i18n_attrs[:count] = settings.max_dice if e == "dice.excessive.quantity"

      msg = I18n.t("#{theme_prefix}.#{e}", i18n_attrs)
      "<div class=\"dice-err-input\">#{warning_emoji} <span class=\"dice-err-msg\">#{msg}</span></div>"
    end.join

    return errors_html
  end

  die_emoji = "🎲"  # :game_die:

  input_html = "<div class=\"dice-input-explain\">#{die_emoji} <span class=\"dice-input\">#{render_dice_input(attrs)}</span></div>"

  results_html = attrs[:raw_results].present? ? render_dice_results(attrs) : ""

  "<blockquote class=\"dice-result\">#{input_html}#{results_html}</blockquote>"
end
