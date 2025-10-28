# frozen_string_literal: true

require 'pagy/extras/limit'
require 'pagy/extras/overflow'
# Optionally override some pagy default with your own in the pagy initializer
Pagy::DEFAULT[:limit] = 50 # items per page
Pagy::DEFAULT[:limit_max] = 500 # items per page
# Better user experience handled automatically
Pagy::DEFAULT[:overflow] = :last_page
