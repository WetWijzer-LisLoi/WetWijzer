# frozen_string_literal: true

# NOTE: Previously attempted to patch SQLite3 schema dumper here.
# That caused load-order issues during initialization. Disabling for now
# to unblock migrations and tests. We can revisit with a safer hook if needed.
