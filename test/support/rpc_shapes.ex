defmodule MPP.Test.RPCShapes do
  @moduledoc false

  # Completes partial JSON-RPC stub results to the full shape a real node returns.
  #
  # onchain 0.16 decodes receipts and transactions strictly: a stub carrying only
  # the fields a test cares about fails to decode. The templates below are real
  # responses, so a stub only states what it asserts on and inherits the rest:
  #
  #   * receipt — Moderato `eth_getTransactionReceipt`, block 0x240d22f
  #     (tx 0xe73c9e33…99d2f), captured 2026-10-02; logs and bloom cleared.
  #   * transaction — Sepolia `eth_getTransactionByHash`, type-2, block 0xb47679
  #     (tx 0x47fbdda6…45d78), captured 2026-10-02; input cleared.
  #
  # Fields present in the partial win, including explicit nils.

  @receipt %{
    "type" => "0x2",
    "status" => "0x1",
    "cumulativeGasUsed" => "0x6946",
    "logs" => [],
    "logsBloom" => "0x" <> String.duplicate("00", 256),
    "transactionHash" => "0xe73c9e33682619c3649453d50db042ef54a3ef059c4889a158572c9777e99d2f",
    "transactionIndex" => "0x0",
    "blockHash" => "0x6953f12b00fc26a960968285d2a22c662b6c24014594f07855c1dfa797b1abe7",
    "blockNumber" => "0x240d22f",
    "gasUsed" => "0x6946",
    "effectiveGasPrice" => "0x23c34601",
    "from" => "0x8b1ed83b55f44d0796443524342f4e832f9fb5f7",
    "to" => "0x009f3df0871c3773cc65976b010e147bcd0a7bfd",
    "contractAddress" => nil
  }

  @transaction %{
    "type" => "0x2",
    "chainId" => "0xaa36a7",
    "nonce" => "0xd44",
    "gas" => "0x124f80",
    "maxFeePerGas" => "0x4e851fab8",
    "maxPriorityFeePerGas" => "0x12cbdd19c",
    "to" => "0x177d490507c85339d25d5f3c67f710a999c7d278",
    "value" => "0x0",
    "accessList" => [],
    "input" => "0x",
    "r" => "0x615dbf067064b0803a9b5bf59518dfcd030b47c2eb57c1758336d77ec115e445",
    "s" => "0x472bb4cb93434e95429dedc3fe5b8ebc57b66ac43fe9c8367c4ec6fe15832091",
    "yParity" => "0x0",
    "v" => "0x0",
    "hash" => "0x47fbdda6f141f63e7801bd5c15af250c9f3fd4761d4abbe8466207d49d945d78",
    "blockHash" => "0x30550aec7dd44dede7ff7d23e7e90a90ec9770ff3b8b1ba9ea2187409ca61bfa",
    "blockNumber" => "0xb47679",
    "transactionIndex" => "0x2",
    "from" => "0x7086fa51a36fdc36a4a922d92cdbeaf7b0a00000",
    "gasPrice" => "0x16a1aac17"
  }

  @doc "Complete a stubbed receipt to a real-node receipt shape."
  def receipt(nil), do: nil
  def receipt(%{} = partial), do: Map.merge(@receipt, partial)

  @doc "Complete a stubbed transaction to a real-node transaction shape."
  def transaction(nil), do: nil
  def transaction(%{} = partial), do: Map.merge(@transaction, partial)

  @doc "Complete a stub result according to the JSON-RPC method that returns it."
  def complete(method, result) when method in ["eth_getTransactionReceipt", "eth_sendRawTransactionSync"],
    do: complete_receipt(result)

  def complete("eth_getTransactionByHash", result), do: complete_transaction(result)
  def complete(_method, result), do: result

  defp complete_receipt(%{} = result), do: receipt(result)
  defp complete_receipt(result), do: result

  defp complete_transaction(%{} = result), do: transaction(result)
  defp complete_transaction(result), do: result
end
