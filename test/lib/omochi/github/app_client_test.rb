require "test_helper"

class Omochi::GitHub::AppClientTest < ActiveSupport::TestCase
  setup do
    @key = OpenSSL::PKey::RSA.generate(2048)
    @key_pem = @key.to_pem
  end

  test "generate_jwt builds a valid RS256 token" do
    client = Omochi::GitHub::AppClient.new(
      app_id: "12345",
      private_key: @key_pem
    )

    jwt = client.generate_jwt
    parts = jwt.split(".")
    assert_equal 3, parts.size

    header = JSON.parse(Base64.urlsafe_decode64(parts[0]))
    payload = JSON.parse(Base64.urlsafe_decode64(parts[1]))

    assert_equal "RS256", header["alg"]
    assert_equal "12345", payload["iss"]
    assert_operator payload["exp"], :>, Time.now.to_i

    # Verify signature with public key
    unsigned = "#{parts[0]}.#{parts[1]}"
    sig = Base64.urlsafe_decode64(parts[2])
    assert @key.public_key.verify(OpenSSL::Digest::SHA256.new, sig, unsigned)
  end

  test "installation_token fetches and caches token" do
    call_count = 0
    fake_response = Struct.new(:code, :body) do
      def [](key)
        nil
      end
    end

    requester = ->(uri, token:, body:) do
      call_count += 1
      fake_response.new("201", { token: "ghs_tok_123", expires_at: (Time.now + 3600).iso8601 }.to_json)
    end

    client = Omochi::GitHub::AppClient.new(
      app_id: "123",
      private_key: @key_pem,
      http_requester: requester
    )

    assert_equal "ghs_tok_123", client.installation_token(99)
    assert_equal "ghs_tok_123", client.installation_token(99)
    assert_equal 1, call_count, "Token should be cached"
  end
end
