# frozen_string_literal: true

module LegalChatbot
  # Constructs system prompts for the LLM based on source type,
  # detected language, and query characteristics.
  #
  # This is a thin delegation layer - the actual prompt content lives
  # in the main LegalChatbotService until the full extraction is complete.
  # The service delegates to this class for all prompt construction.
  class SystemPromptBuilder
    include Prompts
    include Profiles

    # Code-owned prompt version (RAT-003). Ratings collected under different
    # prompt text are not comparable, so BUMP THIS whenever prompt wording
    # changes - including this class, LegalChatbotService#build_system_prompt
    # (which it delegates to), Profiles::CHATBOT_PROFILES, and task/retry
    # instructions assembled by LlmClient, CitationRepair and topic grounding.
    # A change in any of them counts, not only the system-role message.
    #
    # It is a version label, never a hash of the prompt: a prompt hash would
    # be a content fingerprint, which the privacy contract forbids.
    PROMPT_VERSION = 'prompt_2026_10_17_r31'

    HOUSE_HIDDEN_DEFECT_PRACTICAL_SUBJECT_PATTERN = /\b(?:kosten|kost\w*|ereloon\w*|honorari\w*|honoraire\w*|co[uû]t\w*|tarie\w*|uurtarie\w*|fee\w*|cost\w*|hourly|charg\w*|Gebühr\w*|Honorar\w*|Stundensatz|insurance|\p{L}*verzeker\p{L}*|assurance|Rechtsschutz\w*|\p{L}*Versicher\p{L}*|duur|duurt|duren|termijn\w*|duration|timeline\w*|deadline\w*|durée|délai\w*|Dauer|Frist\w*)\b|\bhoe\s+lang\b|\bhow\s+long\b|\bcombien\s+de\s+temps\b|\bwie\s+lange\b/iu

    def self.practical_topic(question)
      return :civil_non_delivery if MarketplaceCivilClaimIntent.topic?(question)

      topic = EuTopicIntent.plan(question)&.dig(:topic)
      topic if %i[flight_disruption platform_redress].include?(topic)
    end

    def initialize(language: 'nl', concise: false, case_context: nil, profile: 'general', international_mode: false)
      @language = language
      @concise = concise
      @case_context = case_context
      @profile = profile
      @international_mode = international_mode == true
    end

    # Build the appropriate system prompt for the given context.
    # Delegates to the main service's build_system_prompt until full extraction.
    def build(source_type, detected_lang: nil, question: nil)
      # This method is called by LlmClient.
      # During the transition phase, the actual prompt building logic
      # remains in LegalChatbotService.build_system_prompt.
      # After full extraction, this will contain the prompt logic directly.
      #
      # For now, we construct a temporary service instance to access the prompt.
      # This avoids duplicating 300+ lines of domain-specific prompt text.
      service = LegalChatbotService.new(language: @language, concise: @concise, case_context: @case_context)
      prompt = service.send(:build_system_prompt, source_type, detected_lang: detected_lang, question: question, international_mode: @international_mode)

      # Legal-application guardrails: derived from the 50 material_legal_error
      # judgments of the 2026-07/08 quality runs. The dominant failure (40%)
      # was anchoring the asked concept to a retrieved but inapplicable
      # article; the rest split over niche-regime overgeneralization,
      # outdated law as current, uncalibrated confidence without sources,
      # and missed exceptions inside the model's own quotes.
      prompt = "#{prompt}\n\n#{legal_application_guardrails}"
      formation_task = formation_deed_task(question)
      prompt = "#{prompt}\n\n#{formation_task}" if formation_task
      coverage_task = unknown_housing_coverage_task(question, detected_lang: detected_lang)
      prompt = "#{prompt}\n\n#{coverage_task}" if coverage_task
      regions_task = all_regions_task(question, detected_lang: detected_lang) unless coverage_task
      prompt = "#{prompt}\n\n#{regions_task}" if regions_task
      housing_task = residential_purchase_finance_task(question, detected_lang: detected_lang)
      prompt = "#{prompt}\n\n#{housing_task}" if housing_task
      house_defect_task = house_hidden_defect_practical_task(question)
      prompt = "#{prompt}\n\n#{house_defect_task}" if house_defect_task
      commute_task = office_commute_work_task(question)
      prompt = "#{prompt}\n\n#{commute_task}" if commute_task
      telephone_privacy_task = telephone_marketing_privacy_task(question)
      prompt = "#{prompt}\n\n#{telephone_privacy_task}" if telephone_privacy_task
      headlight_task = vehicle_headlight_glare_task(question)
      prompt = "#{prompt}\n\n#{headlight_task}" if headlight_task
      municipal_task = municipal_sidewalk_fine_task(question)
      prompt = "#{prompt}\n\n#{municipal_task}" if municipal_task
      commercial_task = commercial_website_task(question)
      prompt = "#{prompt}\n\n#{commercial_task}" if commercial_task
      parallel_employment_task = parallel_employment_task(question)
      prompt = "#{prompt}\n\n#{parallel_employment_task}" if parallel_employment_task
      erasure_task = gdpr_erasure_task(question)
      prompt = "#{prompt}\n\n#{erasure_task}" if erasure_task
      practical_task = practical_source_task(question)
      prompt = "#{prompt}\n\n#{practical_task}" if practical_task
      if MortgageFinanceSources.topic?(question)
        prompt = "#{prompt}\n\nPURCHASE-FINANCE SOURCE TASK: Answer in the resolved answer language. " \
                 'Treat official lender/supervisor guidance as guidance, never as legislation or a credit entitlement. ' \
                 'If no region is specified, discuss Flanders, Brussels and Wallonia separately using only the admitted sources; ' \
                 'name any missing regional coverage. If a region is specified, keep the regional options scoped to it. ' \
                 'Prioritise the reviewed NBB and regional purchase-finance guidance over a parliamentary proposal or a rental-deposit rule. ' \
                 'Explain that assessed property value, purchase costs, income and repayment capacity affect what can actually be financed. ' \
                 'Do not invent current rates, personal eligibility or a guaranteed loan without savings. ' \
                 'Only LITERAL SOURCE EXCERPT text may be quoted; paraphrase the separately labelled reviewed summary. ' \
                 'Use the supplied exact official link, with the institution name, not a fabricated article number.'
      end

      # Append the domain-specialization block for the selected profile
      # (Profiles::CHATBOT_PROFILES). Appending here covers both the default
      # and the French base prompts with one injection point. 'general' (and
      # unknown profiles) contribute nothing.
      addition = self.class.build_profile_prompt(@profile)
      return prompt if addition.blank?

      "#{prompt}\n\n=== PROFIEL-SPECIALISATIE / SPÉCIALISATION PROFIL ===\n#{addition}"
    end

    # Returns the scoped generation guidance that must be repeated next to the
    # rendered evidence. Keeping this public lets LlmClient put the task after
    # the (often very large) source block, where smaller models reliably see it.
    def practical_generation_guidance(question)
      practical_source_task(question)
    end

    # Snel only, on the three practical tasks (v5, Codex 20:30): the short
    # model added unasked procedure and labels it could not verify. Nothing
    # is removed from the evidence; the higher depths are unchanged.
    def practical_quick_scope_guidance
      'SHORT ANSWER SCOPE (Snel): answer only the points the user asked, in short paragraphs. Keep every essential condition, ' \
        'exception and decisive missing fact of those points, and keep any source edition or currentness warning. Cite only the ' \
        'CITABLE UNITS listed below, each with its exact listed label as the link text (a whole article, recital or holding); write ' \
        'no paragraph, point, list or range label. Add no unasked procedural item (default judgments, limitation periods, ' \
        'catalogues of exceptions, appeals) and no authority that is not a listed unit. Use no blockquotes.'
    end

    private

    def practical_topic(question)
      self.class.practical_topic(question)
    end

    def practical_source_task(question)
      topic = practical_topic(question)
      detail = case topic
               when :flight_disruption
                 'Assess the supplied scope rules, operating carrier, booking/connection facts, final-arrival delay and exceptions separately. ' \
                 'Keep departure-delay care and rerouting rights separate from final-arrival compensation. ' \
                 'A carrier assertion about sufficient connection time is not itself a legal exception: establish its significance from the supplied evidence. ' \
                 'Do not promise a fixed compensation amount or unconditional reimbursement; explain any evidenced conditions and missing decisive facts. ' \
                 'Reconstruct outbound and return journeys, their departure points and final destinations separately from the user facts: an EU outbound departure does not establish scope for a return leaving a third country, which needs the applicable operating-carrier condition in the supplied scope rule. ' \
                 'A three-hour final-arrival delay relevant to compensation does not itself activate every refund or rerouting right. Where the supplied delay rule provides a five-hour departure-delay route only to a supplied reimbursement provision, keep it limited to those reimbursement conditions, not rerouting alternatives; do not promise a full refund after a completed journey. ' \
                 'Do not invent paragraph or subparagraph labels not literal in the supplied evidence. ' \
                 'Attribute a statement to a numbered paragraph only when that paragraph\'s own supplied text says it; otherwise link the article without a paragraph number. ' \
                 'Name the return journey in the order the user travelled it, from its third-country departure point to the final destination; never reverse a route. ' \
                 'A two-year period in a supplied Montreal Convention article concerns damages actions under that Convention; do not present it as the deadline for compensation under the Regulation unless a supplied source says so. ' \
                 'Care (meals, refreshments, hotel, transport) for a delay follows the departure-delay and distance thresholds of the supplied delay provision and the conditions of the care provision (hotel only when an overnight stay becomes necessary); state those thresholds. For a cancellation, the cancellation itself triggers care under the supplied provisions, without those delay thresholds (hotel still only when an overnight stay becomes necessary). Never cite the refund/rerouting provision as a source of meals or hotel. ' \
                 'Describe extraordinary circumstances only as the supplied texts do, including that the delay could not have been avoided even if all reasonable measures had been taken and that the carrier must prove it; do not add examples (weather, strikes, political instability, birds) that no supplied source contains. ' \
                 'Do not open with "your situation falls under the Regulation" as a fact: for a return leg from a third country, give the supplied scope conditions as conditions (Community operating carrier; not when benefits or compensation AND assistance were already received in that country) and name the missing facts. ' \
                 'Name the supplied booking and check-in prerequisites of the scope provision as conditions of any scope conclusion. ' \
                 'Name a legal unit only as its supplied markdown link at that exact point, including in a list; do not write a bare article number and link it later. ' \
                 'If a supplied unit cross-references an unsupplied provision, explain the condition in ordinary words without naming that provision.'
               when :platform_redress
                 'Keep reasons, internal complaints, certified out-of-court redress and regulatory complaints distinct. ' \
                 'Assess size/section exemptions and legal-order exceptions rather than asserting that there are no exceptions. ' \
                 'Do not infer formal very-large-platform designation merely from the description large. ' \
                 'When the supplied rule requires qualified human review or supervision, state that condition; do not reduce it to an automated review. ' \
                 'Treat supplied recitals as edition-labelled interpretive context, not independent operative obligations or proof of current legal force. ' \
                 'Never infer a legally operative date from source metadata or an edition date: distinguish entry into force, general application and any section-specific early application only from the supplied operative text. ' \
                 'Treat an Article 19 micro- or small-enterprise rule as a scoped exception to the provisions it actually names, not as an exclusion of the whole DSA. ' \
                 'Likewise, treat an Article 17(5) rule as a scoped exception to that statement-of-reasons obligation, not as an exception from the whole DSA. ' \
                 'For Article 21, preserve the exact supplied timeline, maximum and conditions; do not invent an extension or combine separate time periods. ' \
                 'Article 21 lets a platform refuse to engage with a certified body only when a dispute on the same information and the same grounds has already been resolved; a dispute that is merely pending, before a court or elsewhere, is not that ground. A recital that mentions pending proceedings does not replace that operative condition. ' \
                 'An article number that only appears inside a supplied article (a cross-reference such as Article 24 or 33) and an outside recommendation are not supplied evidence: do not cite them, explain the condition in words. The word "large" in the question does not establish a very-large-platform designation. ' \
                 'Out-of-court settlement covers the listed decisions themselves and complaints not resolved internally; do not make it conditional on first exhausting the internal complaint unless the supplied text says so. ' \
                 'Keep the Article 21 cost rule conditional: the platform bears the body\'s fees and reimburses other reasonable expenses when the body decides in the user\'s favour; a user who loses does not reimburse the platform\'s fees unless the body finds manifest bad faith; for users the procedure is free or for a nominal fee. ' \
                 'Do not state employee, turnover or user-number thresholds for micro, small or very large platforms unless a supplied text states those figures; a reference to a Commission recommendation does not supply them. ' \
                 'Name an article or recital only as its supplied markdown link at that exact point, including repeats and lists; do not write a bare number and link it later. ' \
                 'If a supplied unit cross-references an unsupplied provision, explain the condition or exception in ordinary words without naming that provision.'
               when :civil_non_delivery
                 'Distinguish the creditor demanding performance from the seller merely promising to deliver; a seller promise alone is not the creditor formal demand. ' \
                 'Treat the user\'s stated facts as immutable: a promise to fix or arrange delivery is not a refusal to perform. Do not say the seller refused or waive notice unless that is expressly stated in the question or case-specific evidence supplied by the user, never facts of another dispute in a retrieved judgment. ' \
                 'Distinguish a civil claim from a criminal complaint without presuming fraud. Apply competence and notice qualifications to this goods-sale dispute. ' \
                 'The supplied civil sources do not make a criminal complaint a precondition of the civil claim, but they can neither establish nor exclude that the conduct is a criminal offence such as fraud: never state that the matter is, or is not, a criminal offence. ' \
                 'Article 5.231 defines the formal notice by its content, the creditor\'s clear and unambiguous demand for performance; it does not regulate its form. Do not assert that an oral notice suffices; the creditor must be able to prove the notice, so recommend a dated written demand as practical evidence. ' \
                 'If Article 732 is supplied, a conciliation request counts as a formal notice and suspends limitation for one month only when it contains a claim to a right; state that condition with those effects. ' \
                 'Cite only supplied articles, each with its own link (never "Art. 732 en 733" or a range); an old Civil Code article from memory, for instance on limitation periods, is not supplied and may not be cited. ' \
                 'Do not promise that a default judgment or an undefended claim will be decided in the user\'s favour. ' \
                 'Keep free conciliation, ordinary proceedings and enforcement costs distinct, and do not invent current tariffs or guarantee recovery. ' \
                 'Do not turn optional pre-action conciliation into a mandatory step. Keep its invitation and appearance deadline separate from an ordinary initiating summons; do not call a summons a petition. ' \
                 'Do not confuse means-tested second-line legal aid with legal-expenses insurance, and do not assume either party qualifies. ' \
                 'If Article 1022 is actually supplied, explain its procedural-cost contribution toward a successful party\'s lawyer fees only when its conditions are established; it is not an automatic lawyer-cost allowance, especially when no lawyer or representation facts are supplied. ' \
                 'Its exceptions concern the amount: the judge may reduce or increase it by a specially reasoned decision within the minimum and maximum, and a losing party with second-line legal aid owes the minimum unless the situation is manifestly unreasonable. Never turn that into an absence of any contribution; a heading or list label is a claim too.'
               end
      return nil unless detail

      'PRACTICAL SOURCE TASK: Answer the concrete question in the resolved answer language using only the supplied evidence. Treat the user\'s stated facts as immutable and label hypothetical or missing facts as unestablished. ' \
      'Prefer short, source-linked paraphrases to a long inventory of provisions; normally use about 300-500 words when the supplied distinctions need explanation. ' \
      'Every mention of an article or recital, including a repeated explanation or list item, must itself be a markdown link using its supplied exact URL; copy the complete relative or HTTPS LINK value unchanged, including host, language, CELEX, query and fragment; do not construct or repair URLs. ' \
      'Use paraphrase-first prose and zero blockquotes by default. Literal quotations are optional for this task, overriding any general requirement to quote; use at most one short contiguous quote only when exact wording is essential and present verbatim in the supplied context, unless the user explicitly requests exact source wording. ' \
      'Never translate, reconstruct or stitch a quotation; retain its actual source language if quoting. ' \
      'When a supplied text is in another language than the answer, do not quote it at all: paraphrase it in the answer language with its link. ' \
      'Put the whole reference inside the link label, never the number outside the link; for an EU act the label names the article and at most its paragraph (art. 7(1)), never a point or letter such as onder a) or sub b. ' \
      'Do not claim an exception, deadline, duty or remedy merely from its absence in an excerpt. ' + detail
    end

    def gdpr_erasure_task(question)
      return nil unless EuTopicIntent.plan(question)&.fetch(:topic) == :data_erasure

      'GDPR-ERASURE SOURCE TASK: Answer concisely in the resolved answer language using only the supplied provisions. ' \
        'Former-customer status alone is not a retention justification, but an erasure request alone does not override all lawful necessary processing. ' \
        'Apply an actual Article 17(1) ground and the necessary Article 17(3) exceptions, rather than promising deletion whenever a request is made. ' \
        'Consent withdrawal requires absence of another legal basis. Distinguish Article 21(1) objection from direct-marketing objection under Article 21(2). ' \
        'Article 17(1)(f) concerns the child-related collection referred to in Article 8(1), NOT every information-society service or every website customer. ' \
        'Article 17(3) exceptions apply only to the extent the processing is NECESSARY. For archiving/research/statistics preserve the supplied condition ' \
        'about erasure making the objectives impossible or seriously impairing them; safeguards alone are not a blanket retention exemption. ' \
        'A legal retention obligation must identify particular needed records, purpose and applicable period; it does not justify the whole profile indefinitely. ' \
        'Do not invent example retention periods such as 7 or 10 years, statutory duties, tax regimes or procedural deadlines absent from applicable supplied sources. ' \
        'An internal policy or a speculative future dispute is not by itself a statutory retention obligation. ' \
        'Use short paraphrases with the exact Article17 link; quotations are optional and must not combine or reconstruct source wording. ' \
        'Keep the Dutch/French/German/English prose grammatical and ask which records and legal retention provision are involved when those facts are missing.'
    end

    def parallel_employment_task(question)
      return nil unless question.to_s.match?(LegislationSearch::PARALLEL_EMPLOYMENT_PATTERN)

      'PARALLEL-EMPLOYMENT SOURCE TASK: Answer in the resolved answer language, using only the supplied sources. ' \
        'Apply supplied Article 20 of the Act of 7 October 2022 to work OUTSIDE the employee schedule for OTHER EMPLOYERS, ' \
        'preserving its exception for a prohibition legally permitted. Do not declare the entire contract or every restriction void. ' \
        'Separate own-account/self-employed work: Article 20 does not itself decide that question. Without an applicable supplied ' \
        'authority and sufficient facts, do not assert that a prior-consent clause is automatically valid or automatically invalid. ' \
        'Distinguish DURING-EMPLOYMENT exclusivity/confidentiality/loyalty from a POST-EMPLOYMENT non-compete. ' \
        'Do not require a during-employment own-account restriction to be formulated as a statutory post-employment non-compete ' \
        'with time/place/activity limits. Post-employment rules do not automatically govern the quoted side-work clause. ' \
        'Apply actual supplied Article 17 duties conditionally, including confidentiality and unfair competition, without inventing ' \
        'a universal employer veto. An older judgment cannot override the current statutory other-employer protection. ' \
        'Treat the user contract wording as facts supplied by the user, not as a verified statutory quotation. ' \
        'Ask what side activity, schedule, competitive/confidentiality conflict and employment regime are involved before a definitive own-account conclusion.'
    end

    def commercial_website_task(question)
      return nil unless CommercialWebsiteIntent.topic?(question)

      'COMMERCIAL-WEBSITE SOURCE TASK: Answer in the resolved answer language. ' \
        'Give a useful, source-linked overview for a Belgian commercial service website, rather than replacing the answer ' \
        'with a clarification request or Brussels public-administration portal rules. State the assumed commercial scope ' \
        'and write every heading and label in the answer language (no English label in a Dutch or French answer), ' \
        'then distinguish general service-provider identification/electronic ordering from additional B2C distance-contract duties. ' \
        'For a broad overview, keep the visible answer within about 600 words, grouping related obligations into short paragraphs. ' \
        'Do not enumerate or reproduce every retrieved source: cite the governing articles for each group and preserve decisive exceptions. ' \
        'Do not assume the customers are consumers: describe consumer obligations conditionally and ask B2B/B2C and service type at the end. ' \
        'Use only the supplied current provisions, linking the actual relevant article for each group. ' \
        'For XII.10, distinguish a permitted agreed B2B derogation from an automatic exemption from all provider information; ' \
        'XII.6, § 1, 8° concerns subscribed codes of conduct and their electronic consultation, not identification, and XII.10 limits ' \
        'both the agreed B2B derogation and the e-mail-only exception to the items it lists, so the identification items of XII.6, § 1, ' \
        '1° to 7° remain; ' \
        'the email-only exception is not an ordinary website checkout. The VI.45-53 pack concerns non-financial consumer distance contracts, ' \
        'not a complete financial-services or regulated-profession checklist. ' \
        'Distinguish electronic order acknowledgement under supplied XII.9 from B2C contract confirmation on a durable medium ' \
        'under supplied VI.46; acknowledgement alone is not the whole consumer confirmation duty. ' \
        'If the supplied VI.61/2 is in force, explain the online withdrawal function conditionally instead of calling it merely a draft; ' \
        'do not give an unrestricted withdrawal right where supplied VI.53 excludes it. ' \
        'Distinguish early performance of services from digital content and preserve the supplied consent/acknowledgement conditions. ' \
        'Apply supplied GDPR Articles 6, 13 and 32 only when personal data are processed; consent is not the sole lawful basis, ' \
        'and appropriate security is risk-based, not mandatory encryption of everything. ' \
        'Use supplied Belgian Article 10/2 for cookies/device storage with its strictly necessary exception, not repealed telecom Article 129: ' \
        'it governs storing or accessing information on terminal equipment whether or not that information is personal data, so never ' \
        'place it under a personal-data condition, and keep both technical exceptions (transmitting a communication; a service the user ' \
        'explicitly requested). ' \
        'A privacy notice, contractual terms and a cookie consent mechanism serve different purposes; do not claim every site needs ' \
        'a consent banner or that a checkbox proves compliance. Do not imply the general pack exhausts sector licensing, financial services, ' \
        'intermediary/marketplace or other special obligations. Opinions/proposals are not binding enacted law. ' \
        'Prefer short paraphrases with exact supplied links. Literal quotations are optional for this task; ' \
        'do not reconstruct, translate or stitch statutory quotations.'
    end

    # A marketing objection and erasure request have different effects.
    # Require the model to apply the supplied literal GDPR provisions, not
    # replace the user's central question with a list of disclosure exceptions.
    def telephone_marketing_privacy_task(question)
      return nil unless TelemarketingPrivacyIntent.topic?(question)

      'TELEPHONE-MARKETING PRIVACY SOURCE TASK: Answer in the resolved answer language. ' \
        'Use only the admitted provisions and distinguish source information, access, marketing objection and erasure. ' \
        'If supplied, explain Article 21(2)-(3): objection to processing for direct marketing needs no justification ' \
        'and the data must no longer be processed for that purpose; do not substitute conditional erasure for this right. ' \
        'Use supplied Article 14 for information when data were obtained elsewhere, including its first-contact timing and exceptions. ' \
        'Separately apply supplied Article 15(1)(g) to a request for all available information about the data origin; ' \
        'do not turn Article 14 disclosure exceptions into blanket refusals of an access request. ' \
        'Use supplied Article 17(1)(c) and 17(3) conditionally: a marketing objection can support erasure, ' \
        'but exceptions or another lawful purpose may justify limited retention, without continuing marketing. ' \
        'Do not promise instant deletion over the telephone or immediate removal from every database. ' \
        'If supplied, Article 12(3) requires information on action taken within one month, not merely starting to process the request. ' \
        'Explain any necessary extension and its initial-month notice/reasons only from the supplied provision. ' \
        'For refusal, use supplied Article 12(4) for reasons and complaint/judicial-remedy information. ' \
        'Distinguish automated calls, live calls and fraud; do not assume every unknown caller is an identifiable lawful business. ' \
        'Belgian telephone-marketing rules are additional conditions, not proof of a lawful GDPR basis or a guarantee that a fraudulent caller will comply. ' \
        'Give practical request wording as a suggestion, not as a fabricated statutory quote; never claim personal experience. ' \
        'For this task, literal quotations are optional, overriding any general requirement to quote supplied articles. ' \
        'Prefer concise paraphrase outside quotation marks with the exact supplied provision LINK. ' \
        'If quoting, copy only a short contiguous literal fragment in its native source language, never reconstruct or translate it.'
    end

    def vehicle_headlight_glare_task(question)
      return nil unless VehicleHeadlightGlareSourceScope.topic?(question)

      'HEADLIGHT-GLARE SOURCE TASK: Answer in the resolved answer language. ' \
        'Address the actual glare, accident and insurance question using only the admitted sources. ' \
        'Do not transform the user’s rhetorical question about sunglasses into a duty or recommendation to wear dark glasses at night. ' \
        'Do not list failing to wear sunglasses as contributory fault without an applicable admitted rule establishing that duty. ' \
        'Do not imply that dimming one’s own lamps solves glare caused by another vehicle. ' \
        'Distinguish the other driver’s lighting or technical obligations from the user’s own speed and control duties, ' \
        'and explain only the obligations actually established by the supplied provisions. ' \
        'Glare, SUV height or bright lights alone do not prove a technical defect, fault, causation or automatic immunity. ' \
        'Apply contributory fault conditionally to proven causally relevant conduct, not invented protective measures. ' \
        'For the insurance part, distinguish third-party liability cover from own-vehicle damage only if admitted insurance evidence supports it. ' \
        'If the retrieved sources do not establish coverage or policy consequences, say so explicitly and ask for the relevant policy/evidence; ' \
        'do not promise payment, denial, an insurer’s decision or a particular investigation order. ' \
        'If discussing the applicable road code or Book 6, establish timing from the stated facts and supplied enacted commencement/amendment provisions, ' \
        'not an older date in a title or an assumed accident date. Do not quote an article that was not admitted. ' \
        'For this task, literal quotations are optional, overriding any general requirement to quote supplied articles. ' \
        'Prefer concise paraphrase outside quotation marks with the exact supplied provision LINK. ' \
        'If quoting, copy only a short contiguous literal fragment in its native source language, never reconstruct or translate it.'
    end

    def municipal_sidewalk_fine_task(question)
      return nil unless MunicipalSanctionsSourceScope.topic?(question)

      'MUNICIPAL-SIDEWALK GAS SOURCE TASK: Answer in the resolved answer language. ' \
        'Do not assume the municipality, region, local regulation, responsible person or validity of the fine. ' \
        'Ask which letter and decision stage is involved and when it was notified. ' \
        'For an ordinary GAS allegation/proposed sanction, prioritise the admitted Article 25 defense stage: ' \
        'if its applicable text is supplied, explain registered written defense within fifteen days of notification, ' \
        'dossier access, the report copy, counsel and the conditions for requesting an oral defense. ' \
        'Read the actual paragraph numbering: do not attach that defense right to a different paragraph about register access. ' \
        'Do not replace this initial defense window with the later court-appeal window. ' \
        'For a final sanctioning-officer decision, apply admitted Article 31: ' \
        'the one-month written court petition runs from notification of that decision; distinguish adult police-court and minor youth-court routes. ' \
        'Do not assume adulthood or tell a minor to use the adult court. ' \
        'Do not introduce the special immediate-payment regime or its limits as the ordinary GAS regime. ' \
        'Discuss that special route only if the user actually asks about it or the facts establish its scope, ' \
        'and only with the admitted conditions concerning residence, police collection, consent and exclusions. ' \
        'A quoted immediate-payment ceiling is not a general GAS maximum. ' \
        'Distinguish administrative fines in Article 4 from criminal penalties: its limit on straffen/politiestraffen is not an administrative-fine ceiling or proof of proportionality. ' \
        'A regional municipal code cannot replace current federal GAS provisions when no region is established. ' \
        'A cleanup tax, regional-agency fine or old procedural jurisdiction ruling is not automatically a modern GAS merits precedent. ' \
        'Policy declarations, parliamentary proposals and information reports do not establish the applicable local rule or enforceable deadline. ' \
        'Explain only procedural rights and time limits supported by the admitted applicable text; do not invent a local rule. ' \
        'For this task, literal quotations are optional, overriding any general requirement to quote supplied articles. ' \
        'Prefer concise paraphrase outside quotation marks with the exact supplied provision LINK. ' \
        'If quoting, copy only a short contiguous literal fragment in its native source language, never reconstruct or translate it.'
    end

    # The statutory sales/fee/free-choice provisions do not supply market
    # prices, typical court durations or this buyer's policy terms. Keep the
    # practical answer within the retrieved evidence and the actual facts.
    def house_hidden_defect_practical_task(question)
      text = question.to_s
      return nil unless text.match?(LegislationSearch::HOUSE_PURCHASE_HIDDEN_DEFECT_PATTERN)
      return nil unless text.match?(HOUSE_HIDDEN_DEFECT_PRACTICAL_SUBJECT_PATTERN) ||
                        text.match?(LegislationSearch::LAWYER_FEE_PATTERN) ||
                        text.match?(LegislationSearch::LEGAL_EXPENSE_INSURANCE_PATTERN)

      'HOUSE-HIDDEN-DEFECT PRACTICAL SOURCE TASK: Answer in the resolved answer language. ' \
        'Use only the admitted sources and stated facts for this post-sale dispute. ' \
        'Do not invent numeric hourly rates, letter/consultation prices, court or expert costs, ' \
        'or typical settlement/court timelines, even as rough ranges or personal experience. ' \
        'Give a numeric cost or duration only if an admitted source expressly supplies it and its applicability is established; ' \
        'a judgment date or elapsed time in one case is not a typical litigation-duration estimate. ' \
        'Otherwise say the supplied sources do not establish those figures and suggest obtaining a written fee quote and insurer confirmation. ' \
        'Do not fabricate experiences, lawyer recommendations or predictions of success or settlement. ' \
        'If Art. 446ter is supplied, apply it to the outcome-only fee arrangement it actually regulates; ' \
        'do not turn it into market pricing or a blanket prohibition of every percentage-based fee component. ' \
        'A supplied free-choice-of-lawyer provision does not prove that this claim is insured or that no upfront payment is needed. ' \
        'Do not guarantee coverage, reimbursement, an insurer-funded expert or the absence of upfront costs. ' \
        'Policy coverage, exclusions, limits, deductible, prior insurer approval and payment arrangements are unknown unless established by the stated facts or supplied evidence; ask for confirmation. ' \
        'Discuss an exclusion clause or seller-knowledge exception only conditionally and only as supported by the supplied source; ' \
        'do not assume the contract contains one, that the seller knew of the defect, or that a consumer/professional-seller or abusive-clause regime applies. ' \
        'If an admitted provision or judgment requires action within a short time, prioritise prompt legal assessment and protective steps to preserve the deadline. ' \
        'Do not advise waiting for the expert report before obtaining deadline advice, invent a fixed deadline, ' \
        'or imply that an insurer notification, inspection or expert report by itself preserves or interrupts it.'
    end

    # The location of work is not an occupation or proof that every minute
    # meets the statutory working-time/overtime conditions. Ask the model to
    # apply the supplied provisions to the actual facts, not a railway-staff
    # regime suggested by neighbouring retrieval or colloquial wording.
    def office_commute_work_task(question)
      return nil unless question.to_s.match?(LegislationSearch::OFFICE_COMMUTE_WORK_PATTERN)

      'OFFICE-COMMUTE SOURCE TASK: Answer in the resolved answer language. ' \
        'Begin by explaining that using a laptop or doing work on the train does not by itself establish automatic overtime or a wage premium. ' \
        'This question concerns office work done while commuting, not employment as railway staff; ' \
        'interpret the rhetorical label "treinarbeiders" here as office commuters, not railway employees. ' \
        'Do not call these commuters railway workers or add a railway-sector employment exposition. ' \
        'Do not infer a railway occupation from the location or a colloquial label. ' \
        'Use the admitted working-time and overtime provisions only when their conditions fit the facts. ' \
        'If Articles 19 and 29 are supplied, do not confuse the normal eight-hour daily limit in Article 19 with the quoted nine-hour daily overtime trigger in Article 29. ' \
        'State a numerical threshold only from the supplied provision and together with its applicable conditions, lower limits and exceptions. ' \
        'Preserve its wording about work above a limit rather than treating the limit itself as an inclusive entitlement. ' \
        'Do not derive a single automatic overtime threshold without the actual schedule, applicable collective agreement and employer-disposal facts. ' \
        'Distinguish ordinary travel, voluntary work, work requested or authorised by the employer, ' \
        'and time actually at the employer’s disposal. Do not assume that opening a laptop proves the last condition. ' \
        'Do not assert an absolute rule that unrequested or unauthorised work can never count as working time; assess the actual facts and supplied rule. ' \
        'Do not equate every extra working minute with statutory overtime or an automatic wage premium. ' \
        'Do not declare the employer’s clocking policy unlawful without establishing the relevant conditions. ' \
        'Ask what work is requested or authorised and what working-time arrangement applies if that is missing; ' \
        'specifically ask HR about the actual schedule, applicable collective agreement and treatment of work during the commute. ' \
        'A parliamentary resolution, report or pilot proposal can explain policy debate but does not itself establish an enforceable working-time entitlement. ' \
        'Do not invent people’s motives or diagnose psychological problems from rhetorical questions.'
    end

    def unknown_housing_coverage_task(question, detected_lang: nil)
      text = question.to_s.gsub(/[[:space:]]+/, ' ')
      return nil unless RegionalSearch.partial_housing_coverage_question?(question)
      return nil if LegalChatbot::RegionalSearch::REGION_PATTERNS.values.any? { |pattern| text.match?(pattern) }

      lang = (detected_lang.presence || @language).to_s.downcase
      case lang
      when 'fr'
        'COUVERTURE DES SOURCES POUR LE LOGEMENT: Pour une question sans région, donnez séparément les règles des régions effectivement représentées par les sources et nommez explicitement toute région absente. N’appliquez jamais la règle d’une seule région comme règle belge; ne complétez pas une lacune par une supposition.'
      when 'de'
        'QUELLENABDECKUNG FÜR WOHNRAUM: Bei einer Frage ohne Regionsangabe geben Sie die Regeln der in den Quellen tatsächlich vertretenen Regionen getrennt an und nennen Sie ausdrücklich jede fehlende Region. Wenden Sie niemals die Regel einer einzelnen Region als belgische Regel an; ergänzen Sie Lücken nicht durch Vermutungen.'
      when 'en'
        'HOUSING SOURCE COVERAGE: For a question without a named region, give separate rules for each region actually represented by the sources and explicitly name every region absent from the sources. Never apply one region as Belgian-wide law; do not fill missing coverage by guesswork.'
      else
        'BRONNENDEKKING VOOR HUISVESTING: Geef bij een vraag zonder genoemd gewest de regels van elk gewest dat daadwerkelijk in de bronnen vertegenwoordigd is afzonderlijk en vermeld uitdrukkelijk elk gewest dat in de bronnen ontbreekt. Pas nooit één gewest toe als Belgische hoofdregel en vul ontbrekende dekking niet met aannames aan.'
      end
    end

    # Owner rule (2026-10-17): an answer on a regional subject always mentions
    # all three regions, a named region first, and says so when the sources
    # hold no rule for a region. An unqualified housing question already gets
    # the coverage task above, which asks the same.
    def all_regions_task(question, detected_lang: nil)
      return nil unless RegionalSearch.regional_subject_question?(question)

      language = (detected_lang.presence || @language).to_s.downcase
      task = all_regions_text(language)
      # The regional corpus holds no source of the German-speaking Community
      # (RegionalSearch#scope_to_question_region returns none for it).
      return task unless RegionalSearch.named_regions(question).include?(RegionalSearch::GERMAN_COMMUNITY)

      "#{task} #{GERMAN_COMMUNITY_COVERAGE.fetch(language, GERMAN_COMMUNITY_COVERAGE.fetch('nl'))}"
    end

    GERMAN_COMMUNITY_COVERAGE = {
      'nl' => 'Noemt de vraag de Duitstalige Gemeenschap: de bronnen bevatten geen eigen regels van die Gemeenschap; zeg dat uitdrukkelijk en vul het niet aan met de regel van een gewest.',
      'fr' => 'Si la question vise la Communauté germanophone : les sources ne contiennent aucune règle propre à cette Communauté ; dites-le expressément et ne comblez pas cette lacune avec la règle d’une région.',
      'de' => 'Nennt die Frage die Deutschsprachige Gemeinschaft: Die Quellen enthalten keine eigenen Regeln dieser Gemeinschaft; sagen Sie das ausdrücklich und ergänzen Sie dies nicht durch die Regel einer Region.',
      'en' => 'If the question names the German-speaking Community: the sources hold no rules of that Community; say so explicitly and do not fill the gap with a region’s rule.'
    }.freeze

    def all_regions_text(language)
      case language
      when 'fr'
        'TOUTES LES RÉGIONS: Ce sujet est réglé au niveau régional. Traitez toujours la Flandre, Bruxelles et la Wallonie, chacune séparément et uniquement sur la base des sources; si la question nomme une région, traitez-la d’abord, puis brièvement les deux autres. Si les sources ne contiennent aucune règle pour une région, dites-le expressément; si une règle fédérale s’y applique encore, dites-le. N’appliquez jamais la règle d’une seule région comme règle belge et ne comblez pas une lacune par une supposition.'
      when 'de'
        'ALLE REGIONEN: Dieses Thema ist regional geregelt. Behandeln Sie immer Flandern, Brüssel und Wallonien, jeweils getrennt und ausschließlich auf Grundlage der Quellen; nennt die Frage eine Region, behandeln Sie zuerst diese und danach kurz die beiden anderen. Enthalten die Quellen für eine Region keine Regel, sagen Sie das ausdrücklich; gilt dort noch eine föderale Regel, sagen Sie das. Wenden Sie niemals die Regel einer einzelnen Region als belgische Regel an und ergänzen Sie fehlende Abdeckung nicht durch Vermutungen.'
      when 'en'
        'ALL REGIONS: This subject is regulated regionally. Always cover Flanders, Brussels and Wallonia, each separately and only from the sources; if the question names a region, cover it first and then briefly the other two. If the sources hold no rule for a region, say so explicitly; if a federal rule still applies there, say so. Never apply one region’s rule as Belgian law and do not fill missing coverage by guesswork.'
      else
        'ALLE GEWESTEN: Dit onderwerp is gewestelijk geregeld. Behandel altijd Vlaanderen, Brussel en Wallonië, elk afzonderlijk en uitsluitend op basis van de bronnen; noemt de vraag een gewest, behandel dat gewest dan eerst en daarna kort de twee andere. Bevatten de bronnen voor een gewest geen regel, zeg dat dan uitdrukkelijk; geldt er nog een federale regel, zeg dat. Pas nooit de regel van één gewest toe als Belgische regel en vul ontbrekende dekking niet met aannames aan.'
      end
    end

    # A mixed tenancy/sale/financing question is not permission to infer a
    # forced move or a loan entitlement.  Keep this as a source-use task: it
    # requires regional coverage to remain explicit and preserves the
    # distinction between the tenancy regime, a deposit loan, a mortgage, and
    # a social purchase loan.
    def residential_purchase_finance_task(question, detected_lang: nil)
      text = question.to_s.gsub(/[[:space:]]+/, ' ')
      return nil unless text.match?(LegislationSearch::REGIONAL_HOUSING_SUBJECT_PATTERN) &&
                        text.match?(/\b(?:hypotheek|hypothecair|lening|bank|eigen\s+inbreng|mortgage|loan|down\s+payment|apport|crédit|credit)\b/i) &&
                        text.match?(/\b(?:verkoop|verkopen|verhuurder|huisbaas|verhuizen|selling|landlord|move|moving|sell)\b/i)

      lang = (detected_lang.presence || @language).to_s.downcase
      case lang
      when 'fr'
        'TÂCHE DE SOURCES POUR CETTE QUESTION MIXTE: Si nécessaire, demandez aussi le type de bail et le motif/délai de congé. Ne supposez pas que la vente impose un déménagement. Distinguez strictement garantie locative, prêt de garantie, prêt hypothécaire et prêt social à l’achat. N’inventez ni droit au crédit ni taux/condition; une proposition parlementaire n’est pas une loi en vigueur.'
      when 'de'
        'QUELLENAUFGABE FÜR DIESE GEMISCHTE FRAGE: Fragen Sie nötigenfalls auch nach Mietvertragsart sowie Grund/Frist der Kündigung. Unterstellen Sie nicht, dass ein Verkauf einen Umzug erzwingt. Unterscheiden Sie Mietkaution, Kautionsdarlehen, Hypothek und sozialen Kaufkredit. Erfinden Sie weder einen Kreditanspruch noch Zinssätze/Bedingungen; ein parlamentarischer Vorschlag ist kein geltendes Gesetz.'
      when 'en'
        'SOURCE TASK FOR THIS MIXED QUESTION: Where needed, also ask for the lease type and notice ground/period. Do not assume that a sale forces a move. Keep a rental deposit loan, mortgage, and social purchase loan distinct. Do not invent credit entitlement, rates, or conditions; a parliamentary proposal is not enacted law.'
      else
        'BRONNENTAAK VOOR DEZE GEMENGDE VRAAG: Vraag indien nodig ook welk type huurcontract en welke opzeggingsgrond/-termijn geldt. Neem niet aan dat een verkoop een verhuis verplicht. Houd huurwaarborglening, hypotheek en sociale aankooplening strikt uit elkaar. Verzin geen recht op krediet, tarieven of voorwaarden; een parlementair voorstel is geen geldend recht.'
      end
    end

    # The missing legal form is decisive, not permission for the model to
    # assemble an apparently exhaustive checklist across incompatible forms.
    # Put this in the system role; an instruction among source text proved
    # insufficient on the default model in the production regression probe.
    def formation_deed_task(question)
      question = question.to_s.gsub(/[[:space:]]+/, ' ')
      return nil unless question.match?(LegislationSearch::FORMATION_DEED_PATTERN) &&
                        LegislationSearch.formation_deed_entity_context?(question)

      forms = LegislationSearch.formation_deed_forms(question)
      primary_articles = ['2:5'] + forms.flat_map { |form| LegislationSearch::FORMATION_DEED_FORM_PRIMARY_ARTICLES.fetch(form) }
      if forms.length > 1 && primary_articles.uniq.length > 5
        task = if @language == 'fr'
                 'TÂCHE PRIORITAIRE POUR CETTE QUESTION: La comparaison demandée couvre trop de formes pour les sources limitées fournies. ' \
                   'Répondez en 120 mots maximum et demandez quelles une ou deux formes comparer en premier. ' \
                   "Ne donnez pas une liste prétendument complète des mentions obligatoires et n'inventez pas de rubrique EXCEPTIONS."
               else
                 'PRIORITAIRE TAAK VOOR DEZE VRAAG: De vergelijking omvat te veel rechtsvormen voor de beperkte meegeleverde bronnen. ' \
                   'Antwoord in maximaal 120 woorden en vraag welke één of twee vormen u eerst moet vergelijken. ' \
                   'Geef geen schijnbaar volledige checklist met verplichte vermeldingen en verzin geen rubriek UITZONDERINGEN.'
               end
        return task
      end

      if question.match?(LegislationSearch::FORMATION_DEED_GENERIC_PATTERN)
        task = if @language == 'fr'
                 'TÂCHE PRIORITAIRE POUR CETTE QUESTION: La forme juridique manque. Répondez en 120 mots maximum. ' \
                   'Commencez par une question explicite: quelle forme est visée (SRL, SC, SA, ASBL, AISBL ou fondation)? ' \
                   "Expliquez seulement que les mentions diffèrent selon la forme, avec une référence à l'article 2:5 uniquement s'il est fourni. " \
                   "N'énumérez PAS les mentions obligatoires des différentes formes, n'inventez pas de rubrique EXCEPTIONS. " \
                   'Attendez la précision avant de donner une liste. Cette tâche prévaut sur le format général RÈGLE PRINCIPALE/EXCEPTIONS.'
               else
                 'PRIORITAIRE TAAK VOOR DEZE VRAAG: De rechtsvorm ontbreekt. Antwoord in maximaal 120 woorden. ' \
                   'Begin met een uitdrukkelijke vraag: welke rechtsvorm bedoelt u (BV, CV, NV, VZW, IVZW of stichting)? ' \
                   'Leg alleen uit dat de vermeldingen per vorm verschillen, met een verwijzing naar artikel 2:5 uitsluitend als dat is verstrekt. ' \
                   'Som GEEN verplichte gegevens van de verschillende vormen op en verzin geen rubriek UITZONDERINGEN. ' \
                   'Wacht op de verduidelijking voordat u een checklist geeft. Deze taak gaat voor op de algemene HOOFDREGEL/UITZONDERINGEN-indeling.'
               end
        return task
      end

      cooperative = question.match?(/\b(?:cv(?:ba)?|coöperatieve\s+vennootschap|société\s+coopérative|coopérative|(?-i:SC))\b/i)
      common_articles = forms.filter_map do |form|
        LegislationSearch::FORMATION_DEED_FORM_PRIMARY_ARTICLES.fetch(form).first
      end.uniq.join(', ')
      form_hint = if cooperative
                    if @language == 'fr'
                      'La SC est la société coopérative, pas une société en commandite. '
                    else
                      'CV betekent hier coöperatieve vennootschap, NIET commanditaire vennootschap (Comm.V). '
                    end
                  elsif LegislationSearch.formation_deed_explicit_form(question) == :bv
                    if @language == 'fr'
                      "Pour la SRL, vérifiez sa nature sans capital dans l'article 5:1 fourni; ne transposez pas les exigences de capital de la SA. "
                    else
                      'Controleer voor de BV haar aard zonder kapitaal in het verstrekte artikel 5:1; neem geen kapitaalvereisten van de NV over. '
                    end
                  else
                    ''
                  end
      if @language == 'fr'
        "#{form_hint}TÂCHE POUR L'ACTE CONSTITUTIF: Distinguez mentions de l'acte, mentions statutaires et dépôt/publicité. " \
          "Toutes les données de l'extrait ne sont pas des mentions statutaires: suivez la sélection faite par l'article 2:5. " \
          "Présentez séparément les mentions communes effectivement applicables des articles #{common_articles} et les mentions supplémentaires propres à la forme demandée. " \
          "Résumez concrètement chaque exigence à partir du texte fourni: un simple numéro d'article n'est pas une réponse. " \
          "Classez chaque mention dans les statuts ou dans les autres dispositions de l'acte selon l'article 2:5, sans déplacer les mentions. " \
          "Restez sur le contenu de l'acte demandé; n'ajoutez pas un exposé sur le plan financier ou des EXCEPTIONS non demandées. " \
          "Si la NOTE fournie à l'article 6:13 annule l'alinéa 1er, 4°, mentionnez cette annulation explicitement " \
          'et ne reprenez pas ce point comme une obligation actuelle, même dans une longue citation. Un avertissement final ne corrige pas une liste erronée. ' \
          'Citez seulement les articles effectivement fournis; ne recopiez pas un article entier avec ses renvois internes. ' \
          "Utilisez les liens canoniques de l'article entier: par exemple [Art. 2:5 CSA](/laws/2019A40586#art-2-5). " \
          "Un point d'une énumération (par exemple 4°) n'est pas un article distinct; gardez le lien canonique de l'article."
      else
        "#{form_hint}TAAK VOOR DE OPRICHTINGSAKTE: Onderscheid aktegegevens, statutaire gegevens en neerlegging/openbaarmaking. " \
          'Niet alle gegevens van het uittreksel zijn statutaire vermeldingen: volg de selectie in artikel 2:5. ' \
          "Geef afzonderlijk de werkelijk toepasselijke gemeenschappelijke gegevens uit artikelen #{common_articles} en de bijkomende gegevens van de gevraagde rechtsvorm. " \
          'Vat iedere eis inhoudelijk samen uit de verstrekte tekst: alleen een artikelnummer noemen beantwoordt de vraag niet. ' \
          'Deel iedere vermelding volgens artikel 2:5 in bij de statuten of de overige aktebepalingen; verplaats geen vermeldingen. ' \
          'Blijf bij de gevraagde akte-inhoud; voeg geen uiteenzetting over het financieel plan of ongevraagde UITZONDERINGEN toe. ' \
          'Vermeld een vernietiging uitdrukkelijk als de verstrekte NOTA bij artikel 6:13 het eerste lid, 4°, vernietigt ' \
          'en neem dat punt niet op als een nog geldende verplichting, ook niet in een lang citaat. Een waarschuwing achteraf herstelt geen foutieve checklist. ' \
          'Citeer alleen daadwerkelijk verstrekte artikelen; kopieer geen volledig artikel met al zijn interne verwijzingen. ' \
          'Gebruik de canonieke links naar het hele artikel: bijvoorbeeld [Art. 2:5 WVV](/laws/2019A40586#art-2-5). ' \
          'Een opsommingspunt (bijvoorbeeld 4°) is geen apart artikel; behoud de canonieke link naar het artikel.'
      end
    end

    def legal_application_guardrails
      if @language == 'fr'
        <<~PROMPT.strip
          === RÈGLES D'APPLICATION JURIDIQUE (obligatoires) ===
          1. CONTRÔLE DE CONCEPT : avant d'utiliser un article comme fondement, détermine quelle notion juridique cet article régit réellement. Utilise-le uniquement si cette notion correspond à la question posée. Si aucune source ne régit la notion demandée, dis-le explicitement ; ne présente jamais un article voisin comme s'il régissait la question.
          2. CHAMP D'APPLICATION : si une source ne vaut que pour une région, un secteur ou un régime particulier, nomme cette limite dans la première phrase de la réponse et ne présente jamais un régime particulier comme la règle générale. La langue de la question ou d'une traduction ne prouve pas la région compétente : un texte néerlandais peut aussi traduire un décret wallon. Vérifie la juridiction dans les sources ; si elle n'est pas établie, signale cette limite sans inventer une région.
          3. ACTUALITÉ : vérifie que la règle est encore en vigueur à la date de référence. Les régimes abrogés, transitoires ou de crise doivent être explicitement marqués comme historiques. Pour une entrée en vigueur reportée, utilise la disposition modificative effectivement fournie ; une ancienne date dans le titre ne prime pas cette disposition. Sans preuve suffisante de la date, indique l'incertitude.
          4. PRUDENCE CALIBRÉE : si les sources ne couvrent pas la question, dis que les sources ne la règlent pas. N'affirme jamais une règle - même négative - sans source. Montants, taux et délais uniquement avec référence.
          5. EXCEPTIONS : quand tu cites une disposition, lis aussi les exceptions et conditions contenues dans ce même texte et applique-les.
          6. FAITS DÉCISIFS : ne transforme pas une catégorie courante en conclusion juridique absolue lorsque l'âge, la convention ou la décision judiciaire conditionne la disposition consultée. Nomme la condition et applique seulement les faits fournis ; demande les faits manquants. N'invente aucune exception pour combler une lacune.
        PROMPT
      else
        <<~PROMPT.strip
          === JURIDISCHE TOEPASSINGSREGELS (verplicht) ===
          1. CONCEPT-CHECK: bepaal vóór je een artikel als grondslag gebruikt welk rechtsbegrip dat artikel werkelijk regelt. Gebruik het alleen als dat begrip samenvalt met wat gevraagd wordt. Regelt geen enkele bron het gevraagde begrip, zeg dat dan expliciet; presenteer nooit een aanverwant artikel alsof het de vraag regelt.
          2. TOEPASSINGSGEBIED: geldt een bron alleen voor een gewest, sector of bijzonder stelsel, benoem die beperking dan in de eerste zin van het antwoord en presenteer een bijzonder stelsel nooit als de hoofdregel. De taal van de vraag of een vertaling bewijst niet welk gewest bevoegd is: een Nederlandse tekst kan ook een Waals decreet vertalen. Controleer de jurisdictie in de bronnen; is die niet vastgesteld, vermeld die beperking zonder een gewest te verzinnen.
          3. ACTUALITEIT: controleer of de regeling op de peildatum nog geldt. Opgeheven, tijdelijke of crisisregelingen markeer je uitdrukkelijk als historisch. Gebruik bij uitgestelde inwerkingtreding de daadwerkelijk verstrekte wijzigingsbepaling; een oude datum in de titel gaat niet boven die bepaling. Ontbreekt voldoende bewijs voor de datum, vermeld dan de onzekerheid.
          4. GEKALIBREERDE VOORZICHTIGHEID: dekken de bronnen de vraag niet, zeg dan dat de bronnen dit niet regelen. Stel nooit een regel - ook geen ontkennende - zonder bron. Bedragen, tarieven en termijnen alleen met bronvermelding.
          5. UITZONDERINGEN: citeer je een bepaling, lees dan ook de uitzonderingen en voorwaarden in datzelfde citaat en pas ze toe.
          6. BESLISSENDE FEITEN: maak van een alledaagse categorie geen absolute juridische conclusie als de geraadpleegde bepaling afhangt van leeftijd, overeenkomst of rechterlijke beslissing. Benoem de voorwaarde en pas alleen de gegeven feiten toe; vraag naar ontbrekende feiten. Verzin geen uitzondering om een leemte op te vullen.
        PROMPT
      end
    end
  end
end
