defmodule MPP.Methods.Tempo.KeyAuthorization do
  @moduledoc """
  Tempo subscription key-authorization wire codec and verifier.

  The RLP layout and primitive signature envelopes match `ox/tempo`'s
  `KeyAuthorization`; subscription scope checks follow the normative Tempo
  subscription draft.
  """

  alias Cartouche.Hash
  alias MPP.Hex
  alias MPP.Intents.Subscription
  alias MPP.Methods.Tempo.SignatureEnvelope
  alias Onchain.Address

  @transfer_selector <<0xA9, 0x05, 0x9C, 0xBB>>
  @transfer_with_memo_selector <<0x95, 0x77, 0x7D, 0x59>>
  @day_seconds 86_400
  @week_seconds 604_800
  @uint64_max 18_446_744_073_709_551_615
  @max_safe_integer 9_007_199_254_740_991
  @web_authn_min_authenticator_size 37

  @type key_type :: :secp256k1 | :p256 | :web_authn
  @type t :: %__MODULE__{
          chain_id: non_neg_integer(),
          key_type: key_type(),
          key_id: String.t(),
          expiry: pos_integer(),
          limits: [map()],
          scopes: [map()],
          signature: binary(),
          source: String.t(),
          field: list()
        }

  @enforce_keys [:chain_id, :key_type, :key_id, :expiry, :limits, :scopes, :signature, :source, :field]
  defstruct [:chain_id, :key_type, :key_id, :expiry, :limits, :scopes, :signature, :source, :field]

  @doc "Deserialize and cryptographically verify a signed primitive key authorization."
  @spec deserialize(String.t()) :: {:ok, t()} | {:error, String.t()}
  def deserialize(serialized) when is_binary(serialized) do
    with {:ok, bytes} <- decode_hex(serialized),
         {:ok, [authorization, signature] = field} <- decode_rlp(bytes),
         {:ok, parsed} <- parse_authorization(authorization),
         {:ok, source} <- verify_signature(authorization, signature) do
      {:ok, struct!(__MODULE__, Map.merge(parsed, %{signature: signature, source: source, field: field}))}
    end
  end

  def deserialize(_serialized), do: {:error, "invalid keyAuthorization payload"}

  @doc "Verify that a signed authorization is exactly scoped to a subscription request."
  @spec verify(t(), Subscription.t(), keyword()) :: :ok | {:error, String.t()}
  def verify(%__MODULE__{} = authorization, %Subscription{} = subscription, opts) do
    with {:ok, chain_id} <- required_integer(opts, :chain_id),
         {:ok, access_key} <- required_address(opts, :access_key),
         {:ok, key_type} <- required_key_type(opts, :key_type),
         :ok <- equal(authorization.chain_id, chain_id, "keyAuthorization chainId mismatch"),
         :ok <- address_equal(authorization.key_id, access_key, "keyAuthorization access key mismatch"),
         :ok <- equal(authorization.key_type, key_type, "keyAuthorization key type mismatch"),
         {:ok, expiry} <- subscription_expiry(subscription.subscription_expires),
         :ok <- equal(authorization.expiry, expiry, "keyAuthorization expiry mismatch"),
         :ok <- validate_challenge_expiry(expiry, opts[:challenge_expires]),
         {:ok, period} <- period_seconds(subscription),
         :ok <- verify_limit(authorization.limits, subscription, period),
         :ok <- verify_scopes(authorization.scopes, subscription) do
      verify_declared_source(authorization, opts[:source])
    end
  end

  @doc "Build the normative `wallet_authorizeAccessKey` parameter object."
  @spec wallet_params(Subscription.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def wallet_params(%Subscription{} = subscription, opts) do
    with {:ok, access_key} <- required_address(opts, :access_key),
         {:ok, key_type} <- required_key_type(opts, :key_type),
         {:ok, expiry} <- subscription_expiry(subscription.subscription_expires),
         {:ok, period} <- period_seconds(subscription),
         {:ok, token} <- normalize_address(subscription.currency, "currency"),
         {:ok, recipient} <- normalize_address(subscription.recipient, "recipient"),
         {:ok, amount} <- parse_amount(subscription.amount) do
      {:ok,
       %{
         "address" => access_key,
         "expiry" => expiry,
         "keyType" => key_type_to_wire(key_type),
         "limits" => [
           %{
             "token" => token,
             "limit" => hex_quantity(amount),
             "period" => period
           }
         ],
         "scopes" => [
           %{"address" => token, "selector" => hex(@transfer_selector), "recipients" => [recipient]},
           %{"address" => token, "selector" => hex(@transfer_with_memo_selector), "recipients" => [recipient]}
         ]
       }}
    end
  end

  @doc "Return the decoded RLP field inserted into a Tempo transaction."
  @spec transaction_field(t()) :: list()
  def transaction_field(%__MODULE__{field: field}), do: field

  @doc "Serialize a key authorization as canonical RLP hex."
  @spec serialize(t()) :: String.t()
  def serialize(%__MODULE__{field: field}), do: field |> ExRLP.encode() |> hex()

  @doc "Decode the object returned by `wallet_authorizeAccessKey`."
  @spec from_rpc(map()) :: {:ok, t()} | {:error, String.t()}
  def from_rpc(
        %{
          "chainId" => chain_id,
          "keyId" => key_id,
          "keyType" => key_type,
          "expiry" => expiry,
          "limits" => limits,
          "signature" => signature
        } = rpc
      ) do
    with {:ok, chain_id} <- decode_quantity(chain_id, "chainId"),
         {:ok, key_type} <- rpc_key_type(key_type),
         {:ok, key_id} <- decode_address(key_id, "keyId"),
         {:ok, expiry} <- decode_quantity(expiry, "expiry"),
         {:ok, limits} <- rpc_limits(limits),
         {:ok, scopes} <- rpc_scopes(rpc["allowedCalls"]),
         {:ok, signature} <- rpc_signature(signature) do
      authorization = [encode_uint(chain_id), key_type, key_id, encode_uint(expiry), limits, scopes]
      [authorization, signature] |> ExRLP.encode() |> hex() |> deserialize()
    end
  end

  def from_rpc(_rpc), do: {:error, "wallet_authorizeAccessKey returned an invalid keyAuthorization"}

  @doc "Map a shared subscription period to Tempo's fixed elapsed seconds."
  @spec period_seconds(Subscription.t()) :: {:ok, pos_integer()} | {:error, String.t()}
  def period_seconds(%Subscription{period_unit: unit, period_count: count}) do
    multiplier = if unit == :day, do: @day_seconds, else: if(unit == :week, do: @week_seconds)

    with multiplier when is_integer(multiplier) <- multiplier,
         {period_count, ""} when period_count > 0 <- Integer.parse(count),
         period when period <= @uint64_max <- period_count * multiplier do
      {:ok, period}
    else
      nil -> {:error, "Tempo subscriptions support periodUnit day or week"}
      _ -> {:error, "subscription period cannot be represented as an unsigned 64-bit integer"}
    end
  end

  defp parse_authorization([chain_id, key_type, key_id, expiry, limits, scopes]) do
    with {:ok, chain_id} <- decode_uint(chain_id, "chainId"),
         {:ok, key_type} <- parse_key_type(key_type),
         {:ok, key_id} <- encode_address(key_id, "access key"),
         {:ok, expiry} <- decode_positive_uint(expiry, "expiry"),
         {:ok, limits} <- parse_limits(limits),
         {:ok, scopes} <- parse_scopes(scopes) do
      {:ok, %{chain_id: chain_id, key_type: key_type, key_id: key_id, expiry: expiry, limits: limits, scopes: scopes}}
    end
  end

  defp parse_authorization(_authorization), do: {:error, "keyAuthorization contains unsupported or missing fields"}

  defp parse_limits(limits) when is_list(limits) do
    limits
    |> Enum.reduce_while({:ok, []}, fn
      [token, amount, period], {:ok, acc} ->
        with {:ok, token} <- encode_address(token, "limit token"),
             {:ok, amount} <- decode_uint(amount, "limit amount"),
             {:ok, period} <- decode_positive_uint(period, "limit period") do
          {:cont, {:ok, [%{token: token, amount: amount, period: period} | acc]}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _limit, _acc ->
        {:halt, {:error, "invalid keyAuthorization token limit"}}
    end)
    |> reverse_ok()
  end

  defp parse_limits(_limits), do: {:error, "invalid keyAuthorization token limits"}

  defp parse_scopes(scopes) when is_list(scopes) do
    scopes
    |> Enum.reduce_while({:ok, []}, fn
      [target, rules], {:ok, acc} when is_list(rules) ->
        with {:ok, target} <- encode_address(target, "scope target"),
             {:ok, rules} <- parse_scope_rules(rules) do
          {:cont, {:ok, [%{target: target, rules: rules} | acc]}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _scope, _acc ->
        {:halt, {:error, "invalid keyAuthorization call scope"}}
    end)
    |> reverse_ok()
  end

  defp parse_scopes(_scopes), do: {:error, "invalid keyAuthorization call scopes"}

  defp parse_scope_rules(rules) do
    rules
    |> Enum.reduce_while({:ok, []}, fn
      [selector, recipients], {:ok, acc}
      when is_binary(selector) and byte_size(selector) == 4 and is_list(recipients) ->
        case parse_recipients(recipients) do
          {:ok, recipients} -> {:cont, {:ok, [%{selector: selector, recipients: recipients} | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _rule, _acc ->
        {:halt, {:error, "invalid keyAuthorization selector rule"}}
    end)
    |> reverse_ok()
  end

  defp parse_recipients(recipients) do
    recipients
    |> Enum.reduce_while({:ok, []}, fn recipient, {:ok, acc} ->
      case encode_address(recipient, "scope recipient") do
        {:ok, recipient} -> {:cont, {:ok, [recipient | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_ok()
  end

  defp verify_signature(authorization, signature) when is_binary(signature) do
    digest = authorization |> ExRLP.encode() |> Hash.keccak()

    case signature do
      <<_::binary-size(65)>> -> verify_secp256k1(signature, digest)
      <<0x01, _::binary-size(129)>> -> verify_p256(signature, digest)
      <<0x02, _::binary>> -> verify_web_authn(signature, digest)
      _ -> {:error, "keyAuthorization must use a primitive signature"}
    end
  end

  defp verify_signature(_authorization, _signature), do: {:error, "keyAuthorization must use a primitive signature"}

  defp verify_secp256k1(signature, digest) do
    with {:ok, envelope} <- SignatureEnvelope.deserialize(hex(signature)),
         {:ok, source} <- SignatureEnvelope.extract_address(envelope, digest),
         true <- SignatureEnvelope.verify_secp256k1(envelope, digest, source) do
      {:ok, String.downcase(source)}
    else
      _ -> {:error, "keyAuthorization signature is invalid"}
    end
  end

  defp verify_p256(
         <<0x01, r::binary-size(32), s::binary-size(32), x::binary-size(32), y::binary-size(32), prehash>>,
         digest
       ) do
    digest_type = if prehash == 0, do: :sha256, else: :none
    verify_p256_signature(digest, digest_type, r, s, x, y)
  end

  defp verify_web_authn(<<0x02, data::binary>>, digest) when byte_size(data) >= 128 do
    metadata_size = byte_size(data) - 128

    <<metadata::binary-size(^metadata_size), r::binary-size(32), s::binary-size(32), x::binary-size(32),
      y::binary-size(32)>> = data

    with {:ok, authenticator_data, client_data_json} <- split_web_authn_metadata(metadata),
         {:ok, client_data} <- Jason.decode(client_data_json),
         :ok <- verify_web_authn_challenge(client_data, digest),
         signed = authenticator_data <> :crypto.hash(:sha256, client_data_json),
         {:ok, source} <- verify_p256_signature(signed, :sha256, r, s, x, y) do
      {:ok, source}
    else
      _ -> {:error, "keyAuthorization signature is invalid"}
    end
  end

  defp verify_web_authn(_signature, _digest), do: {:error, "keyAuthorization signature is invalid"}

  defp verify_p256_signature(data, digest_type, r, s, x, y) do
    public_key = <<0x04, x::binary, y::binary>>
    signature = der_signature(r, s)

    if :crypto.verify(:ecdsa, digest_type, data, signature, [public_key, :secp256r1]) do
      {:ok, public_key |> binary_part(1, 64) |> Hash.keccak() |> binary_part(12, 20) |> hex()}
    else
      {:error, "keyAuthorization signature is invalid"}
    end
  rescue
    _error in [ArgumentError, ErlangError] -> {:error, "keyAuthorization signature is invalid"}
  end

  defp split_web_authn_metadata(metadata) do
    range = @web_authn_min_authenticator_size..(byte_size(metadata) - 1)

    Enum.find_value(range, {:error, "invalid WebAuthn metadata"}, fn split ->
      <<authenticator::binary-size(^split), json::binary>> = metadata

      case Jason.decode(json) do
        {:ok, %{} = _decoded} -> {:ok, authenticator, json}
        _ -> false
      end
    end)
  end

  defp verify_web_authn_challenge(%{"challenge" => challenge}, digest) when is_binary(challenge) do
    expected = Base.url_encode64(digest, padding: false)
    if challenge == expected, do: :ok, else: {:error, "WebAuthn challenge mismatch"}
  end

  defp verify_web_authn_challenge(_client_data, _digest), do: {:error, "WebAuthn challenge missing"}

  defp verify_limit([limit], subscription, period) do
    with {:ok, amount} <- parse_amount(subscription.amount),
         :ok <- address_equal(limit.token, subscription.currency, "keyAuthorization currency mismatch"),
         :ok <- equal(limit.amount, amount, "keyAuthorization amount mismatch") do
      equal(limit.period, period, "keyAuthorization period mismatch")
    end
  end

  defp verify_limit(_limits, _subscription, _period),
    do: {:error, "keyAuthorization must contain exactly one token limit"}

  defp verify_scopes([%{target: target, rules: rules}], subscription) do
    with :ok <- address_equal(target, subscription.currency, "keyAuthorization call target mismatch"),
         {:ok, recipient} <- normalize_address(subscription.recipient, "recipient") do
      verify_scope_rules(rules, recipient)
    end
  end

  defp verify_scopes(_scopes, _subscription),
    do: {:error, "keyAuthorization must contain exactly one restricted call target"}

  defp verify_scope_rules(rules, recipient) do
    selectors = Enum.map(rules, & &1.selector)

    cond do
      rules == [] ->
        {:error, "keyAuthorization must use explicit selector rules"}

      Enum.uniq(selectors) != selectors ->
        {:error, "keyAuthorization contains a duplicate selector"}

      Enum.any?(selectors, &(&1 not in [@transfer_selector, @transfer_with_memo_selector])) ->
        {:error, "keyAuthorization selector not allowed"}

      Enum.any?(rules, &(&1.recipients != [recipient])) ->
        {:error, "keyAuthorization recipient mismatch"}

      @transfer_with_memo_selector not in selectors ->
        {:error, "keyAuthorization must allow transferWithMemo"}

      true ->
        :ok
    end
  end

  defp verify_declared_source(_authorization, nil), do: :ok

  defp verify_declared_source(authorization, source) do
    with {:ok, %{chain_id: chain_id, address: address}} <- MPP.DID.parse_evm_did(source),
         :ok <- equal(chain_id, authorization.chain_id, "credential source chain mismatch") do
      address_equal(address, authorization.source, "credential source does not match signature")
    else
      {:error, :invalid_did} -> {:error, "credential source is invalid"}
      {:error, _reason} = error -> error
    end
  end

  defp validate_challenge_expiry(_subscription_expiry, nil), do: :ok

  defp validate_challenge_expiry(subscription_expiry, challenge_expires) do
    with {:ok, datetime, _offset} <- DateTime.from_iso8601(challenge_expires),
         true <- subscription_expiry > DateTime.to_unix(datetime) do
      :ok
    else
      _ -> {:error, "subscriptionExpires must be strictly later than challenge expires"}
    end
  end

  defp subscription_expiry(nil), do: {:error, "Tempo subscriptions require subscriptionExpires"}

  defp subscription_expiry(value) do
    case DateTime.from_iso8601(value) do
      {:ok, %{microsecond: {0, _precision}} = datetime, _offset} ->
        seconds = DateTime.to_unix(datetime)

        if seconds > 0 and seconds <= @max_safe_integer,
          do: {:ok, seconds},
          else: {:error, "subscriptionExpires cannot be represented in a Tempo key authorization"}

      {:ok, _datetime, _offset} ->
        {:error, "subscriptionExpires must be representable as whole seconds"}

      {:error, _reason} ->
        {:error, "subscriptionExpires is invalid"}
    end
  end

  defp parse_amount(amount) do
    case Integer.parse(amount) do
      {value, ""} when value > 0 -> {:ok, value}
      _ -> {:error, "subscription amount is invalid"}
    end
  end

  defp parse_key_type(<<>>), do: {:ok, :secp256k1}
  defp parse_key_type(<<0>>), do: {:ok, :secp256k1}
  defp parse_key_type(<<1>>), do: {:ok, :p256}
  defp parse_key_type(<<2>>), do: {:ok, :web_authn}
  defp parse_key_type(_type), do: {:error, "invalid keyAuthorization key type"}

  defp required_key_type(opts, key) do
    case opts[key] do
      type when type in [:secp256k1, :p256, :web_authn] -> {:ok, type}
      "secp256k1" -> {:ok, :secp256k1}
      "p256" -> {:ok, :p256}
      "webAuthn" -> {:ok, :web_authn}
      _ -> {:error, "invalid subscription access key type"}
    end
  end

  defp key_type_to_wire(:secp256k1), do: "secp256k1"
  defp key_type_to_wire(:p256), do: "p256"
  defp key_type_to_wire(:web_authn), do: "webAuthn"

  defp required_integer(opts, key) do
    case opts[key] do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> {:error, "invalid #{key}"}
    end
  end

  defp required_address(opts, key), do: normalize_address(opts[key], Atom.to_string(key))

  defp normalize_address(value, name) do
    case Address.normalize(value) do
      {:ok, address} -> {:ok, String.downcase(address)}
      {:error, _reason} -> {:error, "#{name} must be an address"}
    end
  end

  defp encode_address(value, _name) when is_binary(value) and byte_size(value) == 20, do: {:ok, hex(value)}

  defp encode_address(_value, name), do: {:error, "invalid #{name} address"}

  defp decode_uint(value, _name) when is_binary(value), do: {:ok, :binary.decode_unsigned(value)}
  defp decode_uint(_value, name), do: {:error, "invalid keyAuthorization #{name}"}

  defp decode_positive_uint(value, name) do
    with {:ok, integer} <- decode_uint(value, name), true <- integer > 0 do
      {:ok, integer}
    else
      _ -> {:error, "invalid keyAuthorization #{name}"}
    end
  end

  defp decode_hex(value) do
    case Base.decode16(Hex.strip_0x(value), case: :mixed) do
      {:ok, bytes} when byte_size(bytes) > 0 -> {:ok, bytes}
      _ -> {:error, "invalid keyAuthorization payload"}
    end
  end

  defp rpc_key_type("secp256k1"), do: {:ok, <<>>}
  defp rpc_key_type("p256"), do: {:ok, <<1>>}
  defp rpc_key_type("webAuthn"), do: {:ok, <<2>>}
  defp rpc_key_type(_type), do: {:error, "wallet returned an invalid key type"}

  defp rpc_limits(limits) when is_list(limits) do
    limits
    |> Enum.reduce_while({:ok, []}, fn
      %{"token" => token, "limit" => amount, "period" => period}, {:ok, acc} ->
        with {:ok, token} <- decode_address(token, "limit token"),
             {:ok, amount} <- decode_quantity(amount, "limit"),
             {:ok, period} <- decode_quantity(period, "period") do
          {:cont, {:ok, [[token, encode_uint(amount), encode_uint(period)] | acc]}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _limit, _acc ->
        {:halt, {:error, "wallet returned an invalid token limit"}}
    end)
    |> reverse_ok()
  end

  defp rpc_limits(_limits), do: {:error, "wallet returned invalid token limits"}

  defp rpc_scopes(scopes) when is_list(scopes) do
    scopes
    |> Enum.reduce_while({:ok, []}, fn
      %{"target" => target, "selectorRules" => rules}, {:ok, acc} when is_list(rules) ->
        with {:ok, target} <- decode_address(target, "scope target"),
             {:ok, rules} <- rpc_scope_rules(rules) do
          {:cont, {:ok, [[target, rules] | acc]}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _scope, _acc ->
        {:halt, {:error, "wallet returned an invalid call scope"}}
    end)
    |> reverse_ok()
  end

  defp rpc_scopes(_scopes), do: {:error, "wallet returned invalid allowedCalls"}

  defp rpc_scope_rules(rules) do
    rules
    |> Enum.reduce_while({:ok, []}, fn
      %{"selector" => selector, "recipients" => recipients}, {:ok, acc} when is_list(recipients) ->
        with {:ok, selector} <- decode_fixed_hex(selector, 4, "selector"),
             {:ok, recipients} <- rpc_recipients(recipients) do
          {:cont, {:ok, [[selector, recipients] | acc]}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _rule, _acc ->
        {:halt, {:error, "wallet returned an invalid selector rule"}}
    end)
    |> reverse_ok()
  end

  defp rpc_recipients(recipients) do
    recipients
    |> Enum.reduce_while({:ok, []}, fn recipient, {:ok, acc} ->
      case decode_address(recipient, "recipient") do
        {:ok, recipient} -> {:cont, {:ok, [recipient | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_ok()
  end

  defp rpc_signature(%{"type" => "secp256k1", "r" => r, "s" => s} = signature) do
    with {:ok, r} <- decode_quantity(r, "signature r"),
         {:ok, s} <- decode_quantity(s, "signature s"),
         {:ok, parity} <- decode_quantity(signature["yParity"] || "0x0", "signature yParity"),
         true <- parity in [0, 1] do
      {:ok, <<r::unsigned-big-size(256), s::unsigned-big-size(256), parity + 27::8>>}
    else
      _ -> {:error, "wallet returned an invalid secp256k1 signature"}
    end
  end

  defp rpc_signature(%{"type" => "p256", "r" => r, "s" => s, "pubKeyX" => x, "pubKeyY" => y} = signature) do
    with {:ok, r} <- decode_fixed_hex(r, 32, "signature r"),
         {:ok, s} <- decode_fixed_hex(s, 32, "signature s"),
         {:ok, x} <- decode_fixed_hex(x, 32, "public key x"),
         {:ok, y} <- decode_fixed_hex(y, 32, "public key y") do
      prehash = if signature["preHash"] == true, do: 1, else: 0
      {:ok, <<1, r::binary, s::binary, x::binary, y::binary, prehash>>}
    end
  end

  defp rpc_signature(%{
         "type" => "webAuthn",
         "webauthnData" => metadata,
         "r" => r,
         "s" => s,
         "pubKeyX" => x,
         "pubKeyY" => y
       }) do
    with {:ok, metadata} <- decode_hex_value(metadata, "WebAuthn metadata"),
         {:ok, r} <- decode_fixed_hex(r, 32, "signature r"),
         {:ok, s} <- decode_fixed_hex(s, 32, "signature s"),
         {:ok, x} <- decode_fixed_hex(x, 32, "public key x"),
         {:ok, y} <- decode_fixed_hex(y, 32, "public key y") do
      {:ok, <<2, metadata::binary, r::binary, s::binary, x::binary, y::binary>>}
    end
  end

  defp rpc_signature(_signature), do: {:error, "wallet returned an invalid primitive signature"}

  defp decode_quantity(value, _name) when is_integer(value) and value >= 0, do: {:ok, value}

  defp decode_quantity(value, name) when is_binary(value) do
    case Integer.parse(Hex.strip_0x(value), 16) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _ -> {:error, "wallet returned an invalid #{name}"}
    end
  end

  defp decode_quantity(_value, name), do: {:error, "wallet returned an invalid #{name}"}

  defp decode_address(value, name), do: decode_fixed_hex(value, 20, name)

  defp decode_fixed_hex(value, size, name) do
    with {:ok, decoded} <- decode_hex_value(value, name), true <- byte_size(decoded) == size do
      {:ok, decoded}
    else
      _ -> {:error, "wallet returned an invalid #{name}"}
    end
  end

  defp decode_hex_value(value, name) when is_binary(value) do
    case Base.decode16(Hex.strip_0x(value), case: :mixed) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, "wallet returned an invalid #{name}"}
    end
  end

  defp decode_hex_value(_value, name), do: {:error, "wallet returned an invalid #{name}"}

  defp encode_uint(0), do: <<>>
  defp encode_uint(value), do: :binary.encode_unsigned(value)

  defp decode_rlp(bytes) do
    case ExRLP.decode(bytes) do
      [authorization, signature] = decoded when is_list(authorization) and is_binary(signature) -> {:ok, decoded}
      _ -> {:error, "invalid keyAuthorization payload"}
    end
  rescue
    _error in [ArgumentError, ExRLP.DecodeError, FunctionClauseError] ->
      {:error, "invalid keyAuthorization payload"}
  end

  defp der_signature(r, s) do
    r = der_integer(r)
    s = der_integer(s)
    <<0x30, byte_size(r) + byte_size(s), r::binary, s::binary>>
  end

  defp der_integer(value) do
    value = value |> trim_zeroes() |> prepend_der_sign_byte()
    <<0x02, byte_size(value), value::binary>>
  end

  defp trim_zeroes(<<0, rest::binary>>) when byte_size(rest) > 0, do: trim_zeroes(rest)
  defp trim_zeroes(value), do: value

  defp prepend_der_sign_byte(<<first, _::binary>> = value) when first >= 0x80, do: <<0, value::binary>>
  defp prepend_der_sign_byte(value), do: value

  defp equal(value, value, _message), do: :ok
  defp equal(_actual, _expected, message), do: {:error, message}

  defp address_equal(actual, expected, message) do
    if Address.equal?(actual, expected), do: :ok, else: {:error, message}
  end

  defp reverse_ok({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_ok(error), do: error

  defp hex(value), do: "0x" <> Base.encode16(value, case: :lower)
  defp hex_quantity(value), do: "0x" <> String.downcase(Integer.to_string(value, 16))
end
