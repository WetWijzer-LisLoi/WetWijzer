# frozen_string_literal: true

module Api
  # Saved-answer endpoints, split out of the monolithic chatbot controller
  # (FBL-060 step 7). Paths unchanged; action bodies verbatim.
  class ChatbotSavedAnswersController < ChatbotBaseController
    # POST /api/chatbot/save
    # Save an answer to user's profile
    def save
      return render json: { error: 'Login required to save answers' }, status: :unauthorized unless current_user

      saved = current_user.saved_answers.create(
        question: params[:question],
        answer: params[:answer],
        sources: params[:sources],
        language: params[:language] || 'nl',
        title: params[:title],
        category: params[:category]
      )

      if saved.persisted?
        render json: { success: true, id: saved.id }
      else
        render json: { error: saved.errors.full_messages.join(', ') }, status: :unprocessable_entity
      end
    rescue StandardError => e
      Rails.logger.error "[ChatbotSave] #{e.class}"
      render json: { error: 'Save failed' }, status: :internal_server_error
    end

    # GET /api/chatbot/saved
    # Get user's saved answers
    def saved
      return render json: { error: 'Login required' }, status: :unauthorized unless current_user

      answers = current_user.saved_answers.recent
      answers = answers.by_category(params[:category]) if params[:category].present?
      # Bounded collection contract (FBL-041): the client-supplied limit is
      # clamped, never trusted.
      limit = params[:limit].to_i
      limit = 50 unless limit.between?(1, 200)
      answers = answers.limit(limit)

      render json: {
        answers: answers.map do |a|
          {
            id: a.id,
            question: a.question,
            answer: a.answer[0..500],
            sources: a.sources,
            title: a.title,
            category: a.category,
            created_at: a.created_at
          }
        end,
        categories: (current_user ? SavedAnswer.categories_for_user(current_user) : [])
      }
    end

    # DELETE /api/chatbot/saved/:id
    def destroy_saved
      return render json: { error: 'Login required' }, status: :unauthorized unless current_user

      answer = current_user.saved_answers.find_by(id: params[:id])
      if answer&.destroy
        render json: { success: true }
      else
        render json: { error: 'Answer not found' }, status: :not_found
      end
    end
  end
end
