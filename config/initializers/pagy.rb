# frozen_string_literal: true

# Pagy v43 Configuration

# Set default items per page
Pagy.options[:limit] = 50

# Set maximum items per page that users can request
Pagy.options[:limit_max] = 500

# Note: Pagy v43 handles arrays automatically via pagy() method

# Default behavior: out-of-range pages show empty results (no error)
# If you want errors for out-of-range, uncomment:
# Pagy.options[:raise_range_error] = true
