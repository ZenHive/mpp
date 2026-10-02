defmodule MPP.Test.InternalPaymentError do
  @moduledoc false

  import ExUnit.Assertions

  alias MPP.Errors

  @type_uri "https://paymentauth.org/problems/internal-payment-error"
  @detail "An internal payment error occurred."

  @spec assert_error({:error, Errors.t()} | Errors.t()) :: Errors.t()
  def assert_error({:error, %Errors{} = error}), do: assert_error(error)

  def assert_error(%Errors{} = error) do
    assert error.status == 500
    assert error.type == @type_uri
    assert error.detail == @detail
    error
  end

  @spec assert_plug(Plug.Conn.t()) :: map()
  def assert_plug(%Plug.Conn{} = conn) do
    assert conn.status == 500
    assert Plug.Conn.get_resp_header(conn, "www-authenticate") == []
    body = Jason.decode!(conn.resp_body)
    assert body["type"] == @type_uri
    assert body["status"] == 500
    assert body["detail"] == @detail
    body
  end
end
