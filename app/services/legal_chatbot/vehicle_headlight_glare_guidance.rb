# frozen_string_literal: true

module LegalChatbot
  # Adds a small, evidence-gated instruction block for the recurring
  # headlight/glare question. This is guidance for the model, not a legal
  # answer: every link and conclusion must still come from the supplied rows.
  module VehicleHeadlightGlareGuidance
    TARGET_LINKS = %w[
      /laws/1975120109#art-30
      /laws/1975120109#art-8
      /laws/1975120109#art-10
      /laws/1968031501#art-28
      /laws/2024001600#art-6-6
      /laws/2024001600#art-6-18
      /laws/2024001600#art-6-20
      /laws/2024001600#art-6-5
    ].freeze

    def self.guidance(question, context)
      return nil unless VehicleHeadlightGlareSourceScope.topic?(question)

      blocks = context.to_s.split(/\n\s*---\s*\n/)
      supplied_blocks = TARGET_LINKS.filter_map do |link|
        numac = link[%r{/laws/([^#]+)#}, 1]
        article = link[/#art-(.+)\z/, 1]
        blocks.find do |block|
          block.match?(/^NUMAC:\s*#{Regexp.escape(numac)}\s*$/) &&
            block.match?(/^Wet:\s*\S/) &&
            block.match?(/^LINK:\s*#{Regexp.escape(link)}\s*$/) &&
            block.match?(/^Art(?:ikel|icle)?\.?\s*#{Regexp.escape(article).gsub('-', '[./-]')}\b/i) &&
            block.match?(/^LINK:.*\n(?:.|\n)+\S/m)
        end
      end
      return nil if supplied_blocks.empty?

      links = supplied_blocks.filter_map { |block| block[/^LINK:\s*(\S+)\s*$/, 1] }.uniq.join(', ')

      <<~GUIDANCE.strip
        HEADLIGHT-GLARE PRACTICAL CHECK (task instruction, not an additional legal source):
        - Use only the admitted road/technical/liability provisions supplied above; available links include #{links}.
        - Do not turn the user's question about sunglasses into a night-driving duty or protective-measure exception. Do not suggest that not wearing sunglasses proves contributory fault.
        - Separate the other driver's lighting/technical duties from the user's own speed, attention and control duties. State causation and contributory fault conditionally on proven facts; glare alone is not proof.
        - Inspect the admitted sources for insurance coverage. If none establishes the user's coverage or policy consequence, say that the insurance outcome cannot be determined here; do not imply cover or denial from a tort or liability provision alone.
        - Prefer a concise paraphrase. If quoting, use only a short contiguous fragment in the source's original language and cite the exact supplied provision link. Do not invent a rule, quote, insurer decision, coverage result or practical exception.
      GUIDANCE
    end
  end
end
