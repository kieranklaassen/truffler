module Truffler
  module Test
    class LiveCallGuard
      def ask(**)
        raise Truffler::LiveCallInTest, "install a fake Jev client (Truffler::Clients::Fake) before calling Jev in tests"
      end
    end

    class EmbedderGuard
      def embed(*, **)
        raise Truffler::LiveCallInTest, "install Truffler::Embeddings::FakeEmbedder before embedding in tests"
      end
    end
  end
end
