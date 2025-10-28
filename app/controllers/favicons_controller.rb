# frozen_string_literal: true

# == Favicons Controller
#
# Handles dynamic favicon serving based on the request's domain.
# This controller serves different favicon files for different domains/locales.
#
# @example
#   # For requests to 'lisloi.be':
#   # Serves 'public/images/favicon_fr.svg' or 'public/images/favicon_fr.ico'
#
#   # For all other domains (e.g., 'wetwijzer.be'):
#   # Serves 'public/images/favicon_nl.svg' or 'public/images/favicon_nl.ico'
#
# @note The controller first looks for an SVG version of the favicon and falls back
#   to ICO format if the SVG is not found.
#
# @see ApplicationController
class FaviconsController < ApplicationController
  include HostDetection

  # Serves the appropriate favicon based on the request domain
  #
  # The method determines which favicon to serve based on the request's host:
  # - For 'lisloi.be' and its subdomains, serves the French version
  # - For all other domains, serves the Dutch version
  #
  # @return [void]
  # @note The favicon files should be placed in the 'public/images/' directory
  # @note Supports both SVG and ICO formats with SVG being the preferred format
  def show
    send_svg_or_ico(select_favicon)
  end

  private

  def select_favicon
    labels = effective_host.to_s.downcase.split('.')
    labels.include?('lisloi') ? 'favicon_fr.svg' : 'favicon_nl.svg'
  end

  def send_svg_or_ico(favicon_name)
    svg_path = Rails.root.join('public', 'images', favicon_name)
    if File.exist?(svg_path)
      return send_file(svg_path, type: 'image/svg+xml', disposition: 'inline',
                                 filename: 'favicon.svg')
    end

    ico_name = favicon_name.sub('.svg', '.ico')
    ico_path = Rails.root.join('public', 'images', ico_name)
    if File.exist?(ico_path)
      return send_file(ico_path, type: 'image/vnd.microsoft.icon', disposition: 'inline',
                                 filename: 'favicon.ico')
    end

    head :not_found
  end
end
