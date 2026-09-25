class TrufflerChannel < ApplicationCable::Channel
  def subscribed
    user_key = authorized_user_key
    return reject if user_key.blank?

    stream_from "truffler:#{user_key}"
  end

  private

  # Must return the same user key your controllers' Truffler searches derive
  # from `user:` (a record becomes "User:42", anything else its to_s), or nil
  # to reject the subscription. Pings carry only {run_id, section, changed_at}.
  def authorized_user_key
    Truffler::Search::Keystroke.user_key(current_user) if current_user
  end
end
