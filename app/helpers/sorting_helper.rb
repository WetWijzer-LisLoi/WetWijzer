# frozen_string_literal: true

# == Sorting Helper
#
# Provides helpers for creating sortable table headers and managing sort parameters.
# Extracted from ApplicationHelper to reduce its size and improve maintainability.
module SortingHelper
  # Extracts and validates sort parameters for the sort_link_to helper
  # @param name [String] The display name for the sort link
  # @param sort_name [String] The attribute name to sort by
  # @yield [block] Optional block for custom link content
  # @return [Array<String>] Array containing name and sort_name
  # @raise [ArgumentError] If neither name/sort_name nor a block is provided
  # @example
  #   extract_sort_params('Title', 'title') #=> ['Title', 'title']
  #   extract_sort_params { 'Custom Title' } #=> ['Custom Title', 'custom_title']
  def extract_sort_params(name = nil, sort_name = nil, &)
    if block_given?
      [capture(&), name || sort_name]
    elsif name && sort_name
      [name, sort_name]
    else
      raise ArgumentError, 'Either provide both name and sort_name or a block'
    end
  end

  # Gets the current sort parameter from the request
  # @return [String, nil] The current sort parameter or nil if not set
  def extract_current_sort
    params[:sort]
  end

  # Determines the sort direction icon based on current sort
  # @param current_sort [String, nil] The current sort parameter
  # @param sort_name [String] The attribute being sorted
  # @return [String] HTML for the sort icon
  def sort_icon_for(current_sort, sort_name)
    # Default to service's default sort when none specified
    default_sort = if defined?(LawSearchConstants::DEFAULT_SORT)
                     LawSearchConstants::DEFAULT_SORT
                   else
                     'date_desc'
                   end
    effective_sort = current_sort.presence || default_sort
    active = effective_sort.start_with?(sort_name)
    up = effective_sort.ends_with?('_asc')

    active ? active_sort_icon(ascending: up) : neutral_sort_icon
  end

  private

  # Active-state chevron icon
  def active_sort_icon(ascending:)
    classes = 'w-3.5 h-3.5 inline-block text-gray-700 dark:text-gray-200'
    d = ascending ? 'M4.5 15.75 12 8.25l7.5 7.5' : 'M19.5 8.25l-7.5 7.5-7.5-7.5'
    content_tag(:svg, xmlns: 'http://www.w3.org/2000/svg', viewBox: '0 0 24 24', fill: 'none', class: classes) do
      content_tag(:path, nil, d: d, stroke: 'currentColor', 'stroke-width': '1.5', 'stroke-linecap': 'round',
                              'stroke-linejoin': 'round')
    end
  end

  # Neutral-state stacked chevrons
  def neutral_sort_icon
    classes = 'w-4 h-4 inline-block text-gray-400 dark:text-gray-500'
    up_neutral = 'M8 11 L12 7 L16 11'
    down_neutral = 'M8 13 L12 17 L16 13'
    content_tag(:svg, xmlns: 'http://www.w3.org/2000/svg', viewBox: '0 0 24 24', fill: 'none', class: classes) do
      safe_join([
                  content_tag(:path, nil, d: up_neutral, stroke: 'currentColor', 'stroke-width': '1.25',
                                          'stroke-linecap': 'round', 'stroke-linejoin': 'round'),
                  content_tag(:path, nil, d: down_neutral, stroke: 'currentColor', 'stroke-width': '1.25',
                                          'stroke-linecap': 'round', 'stroke-linejoin': 'round')
                ])
    end
  end

  # Determines the next sort direction
  # @param current_sort [String, nil] The current sort parameter
  # @param sort_name [String] The attribute being sorted
  # @return [String] The next sort parameter
  def next_sort_direction(current_sort, sort_name)
    if current_sort == "#{sort_name}_asc"
      "#{sort_name}_desc"
    else
      "#{sort_name}_asc"
    end
  end

  # Defines and permits parameters that can be used in sortable links and filters
  # @return [ActiveSupport::HashWithIndifferentAccess] Permitted parameters hash
  # @note Used to maintain filter state across pagination and sorting
  def permitted_params
    params.slice(
      # Search query
      :title,
      # Legislation types
      :constitution, :law, :decree, :ordinance, :decision, :misc,
      # Content filters
      :hide_abolished, :hide_empty, :hide_missing_translation, :hide_german_translation,
      # Languages
      :lang_nl, :lang_fr,
      # Search scope
      :search_in_title, :search_in_tags, :search_in_text,
      # Search mode
      :search_mode,
      # Priority/sorting
      :prioritize_tags,
      # Pagination
      :page, :per_page,
      # Status
      :completed
    ).permit!.to_h
  end

  # Creates a sortable table header with directional icons
  #
  # @param name [String] The display text for the sortable header
  # @param sort_name [String] The attribute name to sort by
  # @yield [block] Optional block for custom link content
  # @return [ActiveSupport::SafeBuffer] HTML link with sort direction indicator
  # @example Basic usage
  #   <%= sort_link_to 'Title', 'title' %>
  #
  # @example With block
  #   <%= sort_link_to 'Created At', 'created_at' do %>
  #     <i class='fa fa-calendar'></i> Date
  #   <% end %>
  def sort_link_to(name = nil, sort_name = nil, &)
    name, sort_name = extract_sort_params(name, sort_name, &)
    current_sort = extract_current_sort

    icon = sort_icon_for(current_sort, sort_name)
    sort_param = next_sort_direction(current_sort, sort_name)

    link_to url_for(permitted_params.merge(sort: sort_param)),
            class: 'inline-flex items-center space-x-1',
            data: {
              turbo_action: 'replace',
              controller: 'sort-link',
              action: 'click->sort-link#sort'
            } do
      safe_join([name, icon])
    end
  end
end
