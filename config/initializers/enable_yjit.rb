# frozen_string_literal: true

# Enable YJIT JIT compiler for performance (Ruby 3.3+)
if defined?(RubyVM::YJIT.enable)
  Rails.application.config.after_initialize do
    RubyVM::YJIT.enable
  end
end
