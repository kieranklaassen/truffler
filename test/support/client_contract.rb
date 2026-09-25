module Truffler
  module Test
    # Shared behavior every Jev client adapter must satisfy. Including classes
    # define `client_answering(response)`, where response is the parsed
    # TypeSafe body ({"model", "answers", "usage"}), and `client_raising(error)`.
    module ClientContract
      QUESTIONS = {
        "r001__spam" => { "type" => "noul", "instructions" => { "question" => "Spam?", "record" => "r001" } },
        "r001__tone" => { "type" => "choice", "instructions" => "Tone?",
                          "criteria" => { "calm" => nil, "angry" => nil } }
      }.freeze

      RESPONSE = {
        "model" => "jev-1.13",
        "answers" => {
          "r001__spam" => { "type" => "noul", "noul" => 0.25 },
          "r001__tone" => { "type" => "choice", "choice" => "angry",
                            "probabilities" => { "calm" => 0.1, "angry" => 0.9 }, "confidence" => 0.9 }
        },
        "usage" => { "input_tokens" => 120 }
      }.freeze

      STATE = { "task" => "Label records", "records" => { "r001" => { "body" => "Buy cheap watches now" } } }.freeze

      def self.included(base)
        base.test "contract: returns normalized answers for every question" do
          answers = client_answering(RESPONSE).ask(state: STATE, questions: QUESTIONS, model: "jev-1.13")

          assert_in_delta 0.25, answers.noul("r001__spam")
          assert_equal "angry", answers.choice("r001__tone")
          assert_equal "jev-1.13", answers.model
          assert_operator answers.usage.input_tokens, :>, 0
        end

        base.test "contract: a response missing an answer fails whole" do
          partial = RESPONSE.merge("answers" => RESPONSE["answers"].except("r001__tone"))

          assert_raises(Truffler::IncompleteAnswers) do
            client_answering(partial).ask(state: STATE, questions: QUESTIONS)
          end
        end

        base.test "contract: errors become ClientError without the response body" do
          error = assert_raises(Truffler::ClientError) do
            client_raising(Test::HttpError.new(503, "upstream said: Buy cheap watches now")).ask(state: STATE, questions: QUESTIONS)
          end

          assert_equal 503, error.status
          assert_not_includes error.message, "watches"
        end

        base.test "contract: emits one jev_call notification without state" do
          payloads = capture_notifications("truffler.jev_call") do
            client_answering(RESPONSE).ask(state: STATE, questions: QUESTIONS, priority: :live)
          end

          assert_equal 1, payloads.size
          assert_equal :live, payloads.first[:priority]
          assert_equal 2, payloads.first[:question_count]
          assert_not payloads.first.key?(:state)
          assert_not_includes payloads.first.to_s, "watches"
        end
      end
    end

    class HttpError < StandardError
      attr_reader :status

      def initialize(status, body)
        @status = status
        super(body)
      end
    end
  end
end
