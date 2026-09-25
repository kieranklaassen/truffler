module Truffler
  # Provider backup search (R19): on the explicit action, a host-declared
  # provider (Gmail for Cora) runs when the query asks for exact text or the
  # local results are weak, and its state renders in its own section below
  # every local section.
  #
  # The run passed to `start` and returned by `run_finder` is duck-typed. It
  # must respond to:
  #
  #   id                          -> the run id, the only run reference jobs carry
  #   model                       -> the searched ActiveRecord class
  #   query                       -> the raw query text (a String or Search::Query),
  #                                  decrypted by the run on encrypted models
  #   update_section(:provider, state)
  #                               -> stores the section state and pings the host
  #                                  (`section: provider`); called once per transition
  #   candidate_ids               -> the local candidate snapshot, used for the weak
  #                                  check when `start` gets no `local_result:`
  #
  # and may respond to `cancelled?`, `tenant_key`, and `user_key`, which the
  # job honors when present.
  module Providers
    SECTION = :provider
    STATUSES = %i[pending results empty unavailable].freeze

    mattr_accessor :run_finder, default: ->(run_id) { SmartSearch::Run.find(run_id) }

    module_function

    # Returns :exact_text or :weak_local when the provider was enqueued, nil
    # when it does not run. `local_result` is the keystroke Search::Result
    # for the same query; its invite row carries the model's weak definition.
    def start(run, query:, tenant_key:, user_key:, local_result: nil)
      Backup.new(run, query: query, tenant_key: tenant_key, user_key: user_key, local_result: local_result).start
    end

    def find_run(run_id)
      run_finder.call(run_id)
    end

    # The first declared provider, or nil.
    def declared(definition)
      name, options = definition.providers.first
      Provider.new(name, options[:label], options[:search]) if name
    end

    def state(provider, status, **details)
      raise ArgumentError, "unknown provider status #{status}" unless STATUSES.include?(status)

      { status: status, name: provider.name, label: provider.label }.merge(details)
    end

    Provider = Struct.new(:name, :label, :search)
  end
end
