# frozen_string_literal: true

# Ruby 4.0 removed OpenStruct from default autoloads.
# Explicitly require it since we use it for FiscoNet legislation structs
# and article history entries.
require 'ostruct'
