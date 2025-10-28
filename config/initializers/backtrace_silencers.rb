# frozen_string_literal: true

# Remove all backtrace silencers when debugging framework code (BACKTRACE=1)
Rails.backtrace_cleaner.remove_silencers! if ENV['BACKTRACE']
