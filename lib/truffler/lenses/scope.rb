module Truffler
  module Lenses
    # What a lens applies to: the whole app, one tenant, or one user inside a
    # tenant. User keys are held only as keyed digests.
    Scope = Data.define(:type, :tenant_key, :user_digest) do
      def self.app
        new(type: :app, tenant_key: nil, user_digest: nil)
      end

      def self.tenant(tenant_key)
        raise ArgumentError, "a tenant lens needs a tenant key" if tenant_key.blank?

        new(type: :tenant, tenant_key: tenant_key.to_s, user_digest: nil)
      end

      def self.user(tenant_key, user_key)
        raise ArgumentError, "a user lens needs a user key" if user_key.blank?

        new(type: :user, tenant_key: tenant_key&.to_s, user_digest: Lenses.digest(user_key))
      end

      def app? = type == :app
      def tenant? = type == :tenant
      def user? = type == :user

      def scope_key
        case type
        when :app then nil
        when :tenant then tenant_key
        when :user then user_digest
        end
      end
    end
  end
end
