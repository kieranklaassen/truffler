module Truffler
  module Lenses
    # `config.lenses`: who may create lenses, whether the system proposes them
    # from query misses, and the limits every lens runs under (R42, R43).
    #
    #   config.lenses.creators = :tenant_users
    #   config.lenses.authorize_lens = ->(user, scope) { user.admin? || scope.tenant_key == user.account_id.to_s }
    class Settings
      CREATORS = %i[developers tenant_users each_user].freeze

      attr_reader :creators
      attr_accessor :proposals, :expire_after, :spend_cap_usd, :sample_size, :max_questions, :generator,
        :drafter_model, :authorize_lens, :user_key

      def initialize
        @creators = :developers
        @proposals = false
        @expire_after = 30.days
        @spend_cap_usd = 1.0
        @sample_size = 20
        @max_questions = 8
        @generator = nil
        @drafter_model = nil
        @authorize_lens = nil
        @user_key = ->(user) { user.is_a?(ActiveRecord::Base) ? Search::Keystroke.user_key(user) : (user.respond_to?(:id) ? user.id : user) }
      end

      def creators=(value)
        value = value.to_sym
        raise ArgumentError, "config.lenses.creators must be one of #{CREATORS.join(', ')}" unless CREATORS.include?(value)

        @creators = value
      end

      def generator_or_default
        generator || RubyLLMGenerator.new
      end

      def key_for(user)
        key = user_key.call(user)
        key.nil? ? nil : key.to_s
      end
    end
  end
end
