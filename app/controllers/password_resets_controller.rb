# frozen_string_literal: true

class PasswordResetsController < ApplicationController
  def new
    # Show forgot password form
  end

  def create
    user = User.find_by(email: params[:email]&.downcase)
    
    if user
      token = user.generate_reset_token!
      UserMailer.password_reset(user, token).deliver_later
    end
    
    # Always show success to prevent email enumeration
    redirect_to login_path, notice: t('auth.reset_email_sent')
  end

  def edit
    @user = User.find_by(reset_password_token: params[:token])
    
    if @user.nil? || reset_token_expired?(@user)
      redirect_to new_password_reset_path, alert: t('auth.reset_token_invalid')
    end
  end

  def update
    @user = User.find_by(reset_password_token: params[:token])
    
    if @user.nil? || reset_token_expired?(@user)
      redirect_to new_password_reset_path, alert: t('auth.reset_token_invalid')
      return
    end

    if params[:password].blank?
      flash.now[:alert] = t('auth.password_blank')
      render :edit, status: :unprocessable_entity
      return
    end

    if params[:password] != params[:password_confirmation]
      flash.now[:alert] = t('auth.passwords_dont_match')
      render :edit, status: :unprocessable_entity
      return
    end

    @user.password = params[:password]
    @user.password_confirmation = params[:password_confirmation]
    @user.reset_password_token = nil
    @user.reset_password_sent_at = nil

    if @user.save
      redirect_to login_path, notice: t('auth.password_reset_success')
    else
      flash.now[:alert] = @user.errors.full_messages.join(', ')
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def reset_token_expired?(user)
    user.reset_password_sent_at.nil? || user.reset_password_sent_at < 2.hours.ago
  end
end
