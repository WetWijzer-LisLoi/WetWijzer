# frozen_string_literal: true

module Webhooks
  class MollieController < ApplicationController
    skip_before_action :verify_authenticity_token

    def create
      unless MollieConfiguration.valid_webhook_token?(params[:token])
        head :not_found
        return
      end

      payment_id = params[:id].to_s
      unless payment_id.match?(MolliePaymentProcessor::PAYMENT_ID)
        render json: { error: 'invalid payment id' }, status: :bad_request
        return
      end

      snapshot = MollieApiClient.new.get_payment(payment_id)
      unless snapshot['id'] == payment_id
        raise MolliePaymentProcessor::VerificationError, 'fetched payment id mismatch'
      end

      MolliePaymentProcessor.new(snapshot).process!
      head :ok
    rescue MolliePaymentProcessor::VerificationError => e
      # A verified API snapshot that violates the immutable local contract must
      # never grant anything. A retry cannot repair an amount/customer mismatch,
      # so acknowledge it to avoid an endless provider retry storm.
      Rails.logger.error("[Mollie Webhook] Rejected payment snapshot: #{e.message}")
      head :ok
    rescue MolliePaymentProcessor::TransientError,
           MollieApiClient::NetworkError,
           MollieApiClient::InvalidResponseError => e
      Rails.logger.warn("[Mollie Webhook] Temporary processing failure: #{e.class}")
      render json: { error: 'temporarily unavailable' }, status: :service_unavailable
    rescue MollieApiClient::ApiError => e
      if e.retryable?
        render json: { error: 'provider temporarily unavailable' }, status: :service_unavailable
      else
        Rails.logger.error("[Mollie Webhook] Provider rejected payment lookup (HTTP #{e.http_status})")
        head :ok
      end
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.error("[Mollie Webhook] Database processing failed: #{e.class}")
      render json: { error: 'temporarily unavailable' }, status: :service_unavailable
    end
  end
end
