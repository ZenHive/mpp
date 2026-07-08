defmodule MPP.Codec do
  @moduledoc """
  Shared base64url→JSON token decoding for the wire-format modules
  (`MPP.Credential`, `MPP.Receipt`, `MPP.Methods.Tempo.SessionReceipt`).

  Owns exactly the decode→error-tag step; callers keep their own downstream
  shape validation (`from_map/1`) and any pre-checks (e.g. a token-size cap).
  """

  @doc """
  Decode a base64url (no padding) JSON string into its parsed term.

  Returns `{:ok, decoded}` where `decoded` is the parsed JSON value, or a tagged
  error: `{:error, :invalid_base64}` when the string is not valid base64url, and
  `{:error, :invalid_json}` when the decoded bytes are not valid JSON.
  """
  @spec decode_base64_json(String.t()) :: {:ok, term()} | {:error, :invalid_base64 | :invalid_json}
  def decode_base64_json(encoded) when is_binary(encoded) do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, decoded} <- Jason.decode(json) do
      {:ok, decoded}
    else
      :error -> {:error, :invalid_base64}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
    end
  end
end
