# frozen_string_literal: true

# Pagy v43 Configuration

# Set default items per page
Pagy::OPTIONS[:limit] = 50

# Set maximum items per page that users can request
Pagy::OPTIONS[:limit_max] = 500

# NOTE: Pagy v43 handles arrays automatically via pagy() method

# Default behavior: out-of-range pages show empty results (no error)
# If you want errors for out-of-range, uncomment:
# Pagy::OPTIONS[:raise_range_error] = true
