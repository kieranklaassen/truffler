module Truffler
  module Lenses
    # Who may create, regenerate, activate, and restore lenses (R42).
    #
    # `config.lenses.creators` bounds the scopes a lens may have:
    #   :developers   - any scope, for users the host hook marks as developers or admins
    #   :tenant_users - tenant or personal lenses, for users of that tenant
    #   :each_user    - personal lenses only, for their own creator
    # The host hook `config.lenses.authorize_lens.call(user, scope)` always has
    # the final word; without one, every change is refused.
    module Policy
      SCOPES = { developers: %i[app tenant user], tenant_users: %i[tenant user], each_user: %i[user] }.freeze

      module_function

      def authorize!(user, scope, model: nil, settings: Lenses.settings)
        allowed = SCOPES.fetch(settings.creators)
        unless allowed.include?(scope.type)
          raise NotAuthorized, "#{scope.type} lenses are not allowed when lens creators are #{settings.creators}"
        end
        if settings.creators == :each_user && scope.user_digest != digest_for(user, settings: settings)
          raise NotAuthorized, "a personal lens can only be changed by its own user"
        end

        hook = settings.authorize_lens
        raise NotAuthorized, "configure config.lenses.authorize_lens to allow lens changes" unless hook
        raise NotAuthorized, "not allowed to change #{scope.type} lenses#{" on #{model.name}" if model}" unless hook.call(user, scope)

        true
      end

      def allowed?(user, scope, **options)
        authorize!(user, scope, **options)
      rescue NotAuthorized
        false
      end

      def digest_for(user, settings: Lenses.settings)
        return if user.nil?

        key = settings.key_for(user)
        Lenses.digest(key) if key.present?
      end
    end
  end
end
