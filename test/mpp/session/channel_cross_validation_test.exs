defmodule MPP.Session.ChannelCrossValidationTest do
  use ExUnit.Case, async: true

  alias MPP.Session.Channel

  @moduletag :cross_validation

  @params %{
    payer: "0x1111111111111111111111111111111111111111",
    payee: "0x2222222222222222222222222222222222222222",
    token: "0x3333333333333333333333333333333333333333",
    salt: "0x0000000000000000000000000000000000000000000000000000000000000001",
    authorized_signer: "0x4444444444444444444444444444444444444444",
    escrow_contract: "0x5555555555555555555555555555555555555555",
    chain_id: 42_431
  }

  test "channel ID matches mppx Channel.ts through its ox ABI/hash primitives" do
    node =
      System.find_executable("node") ||
        flunk("Missing Node.js: install Node and the repository's ox package to run mppx cross-validation")

    {output, exit_status} =
      System.cmd(node, ["--input-type=module", "-e", mppx_script()], stderr_to_stdout: true)

    assert exit_status == 0, "mppx channel-ID oracle failed: #{output}"
    assert {:ok, String.trim(output)} == Channel.compute_id(@params)
  end

  defp mppx_script do
    """
    import { AbiParameters, Hash } from 'ox'
    const encoded = AbiParameters.encode(
      AbiParameters.from([
        'address payer',
        'address payee',
        'address token',
        'bytes32 salt',
        'address authorizedSigner',
        'address escrowContract',
        'uint256 chainId',
      ]),
      [
        '#{@params.payer}',
        '#{@params.payee}',
        '#{@params.token}',
        '#{@params.salt}',
        '#{@params.authorized_signer}',
        '#{@params.escrow_contract}',
        #{@params.chain_id}n,
      ],
    )
    console.log(Hash.keccak256(encoded))
    """
  end
end
