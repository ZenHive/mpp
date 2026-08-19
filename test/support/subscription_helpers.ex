defmodule MPP.Test.SubscriptionHelpers do
  @moduledoc false

  alias Cartouche.Hash
  alias Cartouche.Recover
  alias Cartouche.Signer.Curvy
  alias MPP.Intents.Subscription
  alias MPP.Methods.Tempo.KeyAuthorization
  alias Onchain.Address
  alias Onchain.Log

  @chain_id 42_431
  @root_private_key "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  @access_private_key String.duplicate("22", 32)
  @fee_payer_private_key String.duplicate("33", 32)
  @token "0x20c0000000000000000000000000000000000001"
  @recipient "0x2222222222222222222222222222222222222222"
  @transfer_selector <<0xA9, 0x05, 0x9C, 0xBB>>
  @transfer_with_memo_selector <<0x95, 0x77, 0x7D, 0x59>>
  @transfer_with_memo_event "TransferWithMemo(address,address,uint256,bytes32)"

  @spec chain_id() :: pos_integer()
  def chain_id, do: @chain_id

  @spec token() :: String.t()
  def token, do: @token

  @spec recipient() :: String.t()
  def recipient, do: @recipient

  @spec root_private_key() :: String.t()
  def root_private_key, do: @root_private_key

  @spec access_private_key() :: String.t()
  def access_private_key, do: @access_private_key

  @spec fee_payer_private_key() :: String.t()
  def fee_payer_private_key, do: @fee_payer_private_key

  @spec root_address() :: String.t()
  def root_address, do: address!(@root_private_key)

  @spec access_address() :: String.t()
  def access_address, do: address!(@access_private_key)

  @spec fee_payer_address() :: String.t()
  def fee_payer_address, do: address!(@fee_payer_private_key)

  @spec subscription(keyword()) :: Subscription.t()
  def subscription(opts \\ []) do
    defaults = [
      amount: "1000000",
      currency: @token,
      period_unit: :day,
      period_count: "1",
      recipient: @recipient,
      subscription_expires: future_expiry()
    ]

    defaults
    |> Keyword.merge(opts)
    |> Subscription.new()
    |> then(fn {:ok, subscription} -> subscription end)
  end

  @spec signed_authorization(Subscription.t(), keyword()) :: {String.t(), KeyAuthorization.t(), map()}
  def signed_authorization(%Subscription{} = subscription, opts \\ []) do
    authorization = authorization_tuple(subscription, opts)
    digest = authorization |> ExRLP.encode() |> Hash.keccak()
    private_key = decode_key!(Keyword.get(opts, :root_private_key, @root_private_key))
    {:ok, root_address} = Curvy.get_address(private_key)
    {:ok, signature} = Curvy.sign_payload(digest, private_key)
    signature = Recover.normalize_low_s(signature)
    {:ok, recovery_id} = Recover.find_recid_from_digest(digest, signature, root_address)

    serialized_signature =
      <<signature.r::unsigned-big-size(256), signature.s::unsigned-big-size(256), recovery_id + 27::8>>

    serialized = hex(ExRLP.encode([authorization, serialized_signature]))
    {:ok, parsed} = KeyAuthorization.deserialize(serialized)

    rpc = %{
      "allowedCalls" => rpc_allowed_calls(subscription, opts),
      "chainId" => hex_quantity(Keyword.get(opts, :chain_id, @chain_id)),
      "expiry" => hex_quantity(expiry_seconds(subscription, opts)),
      "keyId" => Keyword.get(opts, :access_key, access_address()),
      "keyType" => "secp256k1",
      "limits" => [
        %{
          "token" => subscription.currency,
          "limit" => hex_quantity(String.to_integer(subscription.amount)),
          "period" => hex_quantity(period_seconds(subscription))
        }
      ],
      "signature" => %{
        "type" => "secp256k1",
        "r" => hex_quantity(signature.r),
        "s" => hex_quantity(signature.s),
        "yParity" => hex_quantity(recovery_id)
      }
    }

    {serialized, parsed, rpc}
  end

  @spec transfer_log(String.t(), String.t(), String.t(), non_neg_integer(), binary()) :: map()
  def transfer_log(token, from, recipient, amount, <<memo::binary-size(32)>>) do
    %{
      "address" => token,
      "topics" => [
        Log.event_topic!(@transfer_with_memo_event),
        address_topic(from),
        address_topic(recipient),
        hex(memo)
      ],
      "data" => amount |> encode_uint() |> left_pad(32) |> hex()
    }
  end

  @spec memo_from_transaction(String.t()) :: binary()
  def memo_from_transaction(raw) do
    {:ok, tx} = Onchain.Tempo.Transaction.deserialize(raw)
    [%{input: input}] = tx.calls
    binary_part(input, byte_size(input) - 32, 32)
  end

  defp authorization_tuple(subscription, opts) do
    {:ok, token} = Address.validate(subscription.currency)
    {:ok, recipient} = Address.validate(subscription.recipient)
    {:ok, access_key} = Address.validate(Keyword.get(opts, :access_key, access_address()))

    rules =
      Keyword.get(opts, :rules, [
        [@transfer_selector, [recipient]],
        [@transfer_with_memo_selector, [recipient]]
      ])

    limits =
      Keyword.get(opts, :limits, [
        [token, encode_uint(String.to_integer(subscription.amount)), encode_uint(period_seconds(subscription))]
      ])

    scopes = Keyword.get(opts, :scopes, [[token, rules]])

    [
      encode_uint(Keyword.get(opts, :chain_id, @chain_id)),
      Keyword.get(opts, :key_type, <<>>),
      access_key,
      encode_uint(expiry_seconds(subscription, opts)),
      limits,
      scopes
    ]
  end

  defp rpc_allowed_calls(subscription, opts) do
    Keyword.get(opts, :rpc_allowed_calls, [
      %{
        "target" => subscription.currency,
        "selectorRules" => [
          %{"selector" => hex(@transfer_selector), "recipients" => [subscription.recipient]},
          %{"selector" => hex(@transfer_with_memo_selector), "recipients" => [subscription.recipient]}
        ]
      }
    ])
  end

  defp expiry_seconds(subscription, opts) do
    Keyword.get_lazy(opts, :expiry, fn ->
      {:ok, expiry, _offset} = DateTime.from_iso8601(subscription.subscription_expires)
      DateTime.to_unix(expiry)
    end)
  end

  defp period_seconds(subscription) do
    {:ok, period} = KeyAuthorization.period_seconds(subscription)
    period
  end

  defp future_expiry do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.shift(day: 30)
    |> DateTime.to_iso8601()
  end

  defp address!(private_key) do
    private_key = decode_key!(private_key)
    {:ok, address} = Curvy.get_address(private_key)
    hex(address)
  end

  defp address_topic(address) do
    {:ok, bytes} = Address.validate(address)
    hex(:binary.copy(<<0>>, 12) <> bytes)
  end

  defp decode_key!("0x" <> key), do: decode_key!(key)
  defp decode_key!(key), do: Base.decode16!(key, case: :mixed)

  defp encode_uint(0), do: <<>>
  defp encode_uint(value), do: :binary.encode_unsigned(value)
  defp left_pad(value, size), do: :binary.copy(<<0>>, size - byte_size(value)) <> value
  defp hex(value), do: "0x" <> Base.encode16(value, case: :lower)
  defp hex_quantity(0), do: "0x0"
  defp hex_quantity(value), do: "0x" <> String.downcase(Integer.to_string(value, 16))
end
