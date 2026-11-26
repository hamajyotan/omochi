module QuestsHelper
  def external_resource_link(resource)
    label = "#{resource.scope_key} #{resource.external_id}"
    uri = URI.parse(resource.url.to_s)
    if uri.is_a?(URI::HTTPS) && uri.host.present?
      link_to(label, uri.to_s, rel: "noopener noreferrer", target: "_blank")
    else
      tag.span(label, class: "mono")
    end
  rescue URI::InvalidURIError
    tag.span(label, class: "mono")
  end

  def status_badge(status)
    icon = case status.to_s
    when "pending" then "💤 "
    when "queued" then "⏳ "
    when "running", "processing" then "✨ "
    when "preparing" then "🌱 "
    when "completed", "succeeded", "processed" then "🎉 "
    when "failed" then "😿 "
    when "cancelled" then "☁️ "
    else ""
    end
    tag.span("#{icon}#{status}", class: "badge badge--#{status}")
  end

  def format_time(time)
    return "—" unless time

    tag.time(l(time.in_time_zone, format: :omochi), datetime: time.iso8601)
  end

  def format_duration(seconds)
    return "—" unless seconds

    seconds < 60 ? format("%.1fs", seconds) : "#{(seconds / 60).floor}m #{(seconds % 60).round}s"
  end

  def pagination_page_numbers(current_page, total_pages, window: 2)
    return (1..total_pages).to_a if total_pages <= (window * 2 + 3)

    pages = [ 1 ]
    left = current_page - window
    right = current_page + window

    pages << :gap if left > 2
    ((left.clamp(2, total_pages))..(right.clamp(1, total_pages - 1))).each do |p|
      pages << p
    end
    pages << :gap if right < total_pages - 1
    pages << total_pages
    pages.uniq
  end
end
