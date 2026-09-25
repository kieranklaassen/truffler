require "test_helper"

class DefinitionTest < Truffler::TestCase
  def define_model(name, table: "emails", &block)
    Class.new(ActiveRecord::Base) do
      self.table_name = table
      define_singleton_method(:name) { name }
      include Truffler::Model
      class_eval(&block) if block
    end
  end

  test "exposes labels with their types, thresholds, and boosts" do
    definition = Email.truffler_definition

    assert_equal %w[needs_action urgent category importance], definition.label_keys
    assert_equal %i[noul noul choice score], definition.labels.values.map(&:type)
    assert_in_delta 0.6, definition.label(:needs_action).filter_at
    assert_in_delta 2.0, definition.label(:needs_action).boost
    assert_nil definition.label(:importance).filter_at
    assert_equal "account_id", definition.tenant_column
    assert_equal %w[subject body sender_name], definition.fields
    assert_equal [ "received_at", :desc ], definition.order
    assert_equal "created_at", definition.arrived_at_column
  end

  test "registers declared models" do
    assert_includes Truffler.registry.models, Email
    assert_includes Truffler.registry.models, SecretNote
  end

  test "reads the tenant key and the fields of a record" do
    email = Email.new(account_id: 7, subject: "Hi", body: "Pay the invoice", sender_name: "Ann")

    assert_equal "7", Email.truffler_definition.tenant_key_for(email)
    assert_equal({ "subject" => "Hi", "body" => "Pay the invoice", "sender_name" => "Ann" },
      Email.truffler_definition.field_values(email))
  end

  test "storage keys give one row per noul and score and one per choice option" do
    definition = Email.truffler_definition

    assert_equal [ "needs_action" ], definition.label(:needs_action).storage_keys
    assert_equal [ "category:billing", "category:travel", "category:other" ], definition.label(:category).storage_keys
    assert_equal [ "importance" ], definition.label(:importance).storage_keys
  end

  test "builds the wire-shape question for each label" do
    assert_equal({ "type" => "score", "instructions" => "How important is this email to the reader?",
                   "criteria" => [ "Ignorable", "Worth a look", "Must read" ] },
      Email.truffler_definition.label(:importance).question)
    assert_equal({ "billing" => "Invoices, receipts, and payments", "travel" => "Trips and bookings", "other" => nil },
      Email.truffler_definition.label(:category).question["criteria"])
  end

  test "reading a missing column raises DefinitionError" do
    error = assert_raises(Truffler::DefinitionError) do
      define_model("MissingColumn") { truffler { reads :missing_column } }
    end
    assert_includes error.message, "missing_column"
  end

  test "0.1.1: declaring on a missing table defers column checks until the first labeling" do
    connection = ActiveRecord::Base.connection
    model = self.class.const_set(:LateNote, define_model("DefinitionTest::LateNote", table: "late_notes"))
    model.truffler do
      tenant :account_id
      reads :title
      label :pinned, :noul, from: ->(note) { note.pinned }
    end

    connection.create_table(:late_notes) do |t|
      t.integer :account_id
      t.string :title
      t.boolean :pinned
    end
    note = model.create!(account_id: 1, title: "Hi", pinned: true)
    drain_jobs

    assert_equal [ [ "pinned", 1.0 ] ], Truffler::Records::Label.where(record_id: note.id).pluck(:label_key, :value)
  ensure
    connection.drop_table(:late_notes, if_exists: true)
    self.class.send(:remove_const, :LateNote) if self.class.const_defined?(:LateNote, false)
  end

  test "0.1.1: unknown columns on a table created after declaration raise at first use" do
    connection = ActiveRecord::Base.connection
    model = define_model("LateBadNote", table: "late_bad_notes")
    model.truffler { reads :nope }

    connection.create_table(:late_bad_notes) { |t| t.string :title }

    error = assert_raises(Truffler::DefinitionError) { model.truffler("x", scope: model.all) }
    assert_match(/unknown attributes nope/, error.message)
  ensure
    connection.drop_table(:late_bad_notes, if_exists: true)
  end

  test "an unknown tenant column raises DefinitionError" do
    assert_raises(Truffler::DefinitionError) do
      define_model("BadTenant") { truffler { tenant :team_id; reads :subject } }
    end
  end

  test "rejects duplicate, unsafe, or malformed labels" do
    assert_raises(Truffler::DefinitionError) do
      define_model("Dup") do
        truffler do
          reads :subject
          label :spam, :noul, question: "?"
          label :spam, :noul, question: "?"
        end
      end
    end
    [ "Spam", "a__b", "1st", "spam-ham" ].each do |key|
      assert_raises(Truffler::DefinitionError, key) do
        define_model("Unsafe") { truffler { reads :subject; label key, :noul, question: "?" } }
      end
    end
    assert_raises(Truffler::DefinitionError) do
      define_model("NoOptions") { truffler { reads :subject; label :tone, :choice, question: "?" } }
    end
    assert_raises(Truffler::DefinitionError) do
      define_model("NoLegend") { truffler { reads :subject; label :size, :score, question: "?" } }
    end
    assert_raises(Truffler::DefinitionError) do
      define_model("BadType") { truffler { reads :subject; label :size, :number, question: "?" } }
    end
  end

  test "a label named lens is reserved for lens dimensions" do
    error = assert_raises(Truffler::DefinitionError) do
      define_model("LensLabel") { truffler { reads :subject; label :lens, :noul, question: "?" } }
    end
    assert_match(/reserved/, error.message)
  end

  test "requires at least one field to read" do
    assert_raises(Truffler::DefinitionError) { define_model("NoReads") { truffler { label :spam, :noul, question: "?" } } }
  end

  test "embeddings on encrypted fields require allow_encrypted" do
    error = assert_raises(Truffler::DefinitionError) do
      define_model("EncryptedNote", table: "secret_notes") do
        encrypts :body
        truffler do
          reads :title, :body
          embeddings
        end
      end
    end
    assert_includes error.message, "allow_encrypted"

    model = define_model("AllowedNote", table: "secret_notes") do
      encrypts :body
      truffler do
        reads :title, :body
        embeddings allow_encrypted: true
      end
    end
    assert_equal({ model: "text-embedding-3-small", dimensions: 256, allow_encrypted: true },
      model.truffler_definition.embeddings)
  end

  test "embeddings can point at an existing column" do
    model = define_model("ColumnEmail") { truffler { reads :subject; embeddings column: :body } }

    assert_equal({ column: "body" }, model.truffler_definition.embeddings)
  end

  test "declares sources, providers, and surfaces for later search stages" do
    keyword_search = ->(scope, _terms) { scope }
    sender_lookup = ->(scope, _token) { scope }
    gmail = ->(_query, tenant:, user:) { [] }
    model = define_model("Sources") do
      truffler do
        reads :subject
        keyword keyword_search
        exact :sender, sender_lookup
        provider :gmail, label: "Gmail", search: gmail
        surface :palette, explicit_action: :row
        arrived_at :received_at
      end
    end
    definition = model.truffler_definition

    assert_same keyword_search, definition.keyword
    assert_equal({ "sender" => sender_lookup }, definition.exact_sources)
    assert_equal({ "gmail" => { label: "Gmail", search: gmail } }, definition.providers)
    assert_equal({ "palette" => { explicit_action: :row } }, definition.surfaces)
    assert_equal "received_at", definition.arrived_at_column
  end

  test "keyword accepts column names and rejects unknown surfaces actions" do
    model = define_model("KeywordColumns") { truffler { reads :subject; keyword :subject, :body } }
    assert_equal %w[subject body], model.truffler_definition.keyword

    assert_raises(Truffler::DefinitionError) do
      define_model("BadSurface") { truffler { reads :subject; surface :page, explicit_action: :click } }
    end
  end

  test "choice options given as a callable of the tenant make the vocabulary per-tenant" do
    model = define_model("PerTenant") do
      truffler do
        reads :subject
        label :folder, :choice, question: "Which folder?", options: ->(tenant) { tenant == "1" ? %w[work home] : %w[school] }
      end
    end

    assert model.truffler_definition.per_tenant_vocabulary?
    assert_not Email.truffler_definition.per_tenant_vocabulary?
    assert_equal [ "folder:work", "folder:home" ], model.truffler_definition.label(:folder).storage_keys("1")
  end
end
