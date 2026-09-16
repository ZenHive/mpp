defmodule MPP.JsonRpcErrorInvariantTest do
  use ExUnit.Case, async: true

  test "payment error code literals exist only in Mcp's constants" do
    for path <- Path.wildcard("lib/**/*.ex") do
      ast = path |> File.read!() |> Code.string_to_quoted!()

      Macro.prewalk(ast, fn
        {:@, _, [{name, _, [{:-, _, [value]}]}]} = node
        when name in [:payment_required_code, :verification_failed_code, :invalid_params_code, :internal_error_code] ->
          assert path == "lib/mpp/mcp.ex"
          assert value in [32_042, 32_043, 32_602, 32_603]
          # Do not descend into the permitted constant declaration.
          {:constant, [], [Macro.to_string(node)]}

        {:-, _, [value]} = node when value in [32_042, 32_043, 32_602, 32_603] ->
          flunk("JSON-RPC payment code outside Mcp constants in #{path}: #{Macro.to_string(node)}")

        node ->
          node
      end)
    end
  end

  test "new JSON-RPC error constructors require conformance coverage" do
    # Keep this inventory tied to the all-problem matrix in McpTest. Discover
    # constructors across lib, including private emitters behind public APIs.
    emitters =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.flat_map(&error_constructors/1)
      |> Enum.sort()

    assert emitters == [
             {"lib/mpp/mcp.ex", :payment_required_error, 1},
             {"lib/mpp/mcp.ex", :verification_failed_error, 2},
             {"lib/mpp/transports/json_rpc/adapter.ex", :error_response, 5},
             # Envelope parse/invalid-request errors have no MPP problem.
             # Their -32700/-32600 contract is covered in JsonRpc.PlugTest.
             {"lib/mpp/transports/json_rpc/plug.ex", :rpc_error, 3}
           ]
  end

  defp error_constructors(path) do
    {_ast, emitters} =
      path
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {kind, _, [head, body]} = node, acc when kind in [:def, :defp] ->
          {name, _, args} = unguard(head)

          if error_map?(body) do
            {node, [{path, name, length(args || [])} | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(emitters)
  end

  defp unguard({:when, _, [head | _guards]}), do: head
  defp unguard(head), do: head

  defp error_map?(body) do
    {_ast, found?} =
      Macro.prewalk(body, false, fn
        {:%{}, _, entries} = node, found? ->
          keys = for {key, _value} <- entries, do: key
          {node, found? or ("code" in keys and "message" in keys) or (:code in keys and :message in keys)}

        node, found? ->
          {node, found?}
      end)

    found?
  end
end
