defmodule MPP.Methods.Solana.Ristretto255 do
  @moduledoc false

  import Bitwise

  @field_prime (1 <<< 255) - 19
  @scalar_order 7_237_005_577_332_262_213_973_186_563_042_994_240_857_116_359_379_907_606_001_950_938_285_454_250_989
  @edwards_d 37_095_705_934_669_439_343_138_083_508_754_565_189_542_113_879_843_219_016_388_785_533_085_940_283_555
  @sqrt_m1 19_681_161_376_707_505_956_807_079_304_988_542_015_446_066_515_923_890_162_744_021_073_123_829_784_752
  @pow_p58 div(@field_prime - 5, 8)
  @compressed_basepoint Base.decode16!("E2F2AE0A6ABC4E71A884A961C500515F58E30B6AA582DD8DB6A65945E08D2D76")

  @type point :: {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
  @type ciphertext :: {binary(), binary()}

  @doc false
  @spec decode_scalar(binary()) :: {:ok, pos_integer()} | :error
  def decode_scalar(<<_::binary-size(32)>> = bytes) do
    scalar = :binary.decode_unsigned(bytes, :little)
    if scalar > 0 and scalar < @scalar_order, do: {:ok, scalar}, else: :error
  end

  def decode_scalar(_bytes), do: :error

  @doc false
  @spec delta_matches?(ciphertext(), ciphertext(), non_neg_integer(), pos_integer()) :: boolean()
  def delta_matches?({before_commitment, before_handle}, {after_commitment, after_handle}, amount, secret)
      when is_integer(amount) and amount >= 0 and is_integer(secret) and secret > 0 do
    with {:ok, before_commitment} <- decompress(before_commitment),
         {:ok, before_handle} <- decompress(before_handle),
         {:ok, after_commitment} <- decompress(after_commitment),
         {:ok, after_handle} <- decompress(after_handle),
         {:ok, basepoint} <- decompress(@compressed_basepoint) do
      commitment_delta = subtract(after_commitment, before_commitment)
      handle_delta = subtract(after_handle, before_handle)
      decrypted = subtract(commitment_delta, multiply(handle_delta, secret))
      equal?(decrypted, multiply(basepoint, amount))
    else
      _error -> false
    end
  end

  @doc false
  @spec decompress(binary()) :: {:ok, point()} | :error
  def decompress(<<_::binary-size(32)>> = encoded) do
    s = :binary.decode_unsigned(encoded, :little)

    if s < @field_prime and !negative?(s) do
      decompress_canonical(s)
    else
      :error
    end
  end

  def decompress(_encoded), do: :error

  defp decompress_canonical(s) do
    ss = field(s * s)
    u1 = field(1 - ss)
    u2 = field(1 + ss)
    u2_squared = field(u2 * u2)
    v = field(-@edwards_d * u1 * u1 - u2_squared)
    {square?, inverse_sqrt} = sqrt_ratio(1, field(v * u2_squared))
    dx = field(inverse_sqrt * u2)
    dy = field(inverse_sqrt * dx * v)
    x = absolute(field(2 * s * dx))
    y = field(u1 * dy)
    t = field(x * y)

    if square? and !negative?(t) and y != 0, do: {:ok, {x, y, 1, t}}, else: :error
  end

  defp sqrt_ratio(u, v) do
    v3 = field(v * v * v)
    v7 = field(v3 * v3 * v)
    root = field(u * v3 * mod_power(field(u * v7), @pow_p58))
    check = field(v * root * root)
    negative_u = field(-u)

    root =
      if check == negative_u or check == field(negative_u * @sqrt_m1),
        do: field(root * @sqrt_m1),
        else: root

    {check == field(u) or check == negative_u, absolute(root)}
  end

  defp multiply(point, scalar), do: multiply(point, scalar, identity(), 0)

  defp multiply(_point, _scalar, result, 255), do: result

  defp multiply(point, scalar, result, bit) do
    added = add(result, point)
    result = if (scalar &&& 1 <<< bit) == 0, do: result, else: added
    multiply(add(point, point), scalar, result, bit + 1)
  end

  defp add({x1, y1, z1, t1}, {x2, y2, z2, t2}) do
    a = field((y1 - x1) * (y2 - x2))
    b = field((y1 + x1) * (y2 + x2))
    c = field(2 * @edwards_d * t1 * t2)
    d = field(2 * z1 * z2)
    e = field(b - a)
    f = field(d - c)
    g = field(d + c)
    h = field(b + a)
    {field(e * f), field(g * h), field(f * g), field(e * h)}
  end

  defp subtract(left, {x, y, z, t}), do: add(left, {field(-x), y, z, field(-t)})

  defp equal?({x1, y1, _z1, _t1}, {x2, y2, _z2, _t2}) do
    field(x1 * y2) == field(y1 * x2) or field(x1 * x2) == field(y1 * y2)
  end

  defp identity, do: {0, 1, 1, 0}
  defp negative?(value), do: (field(value) &&& 1) == 1
  defp absolute(value), do: if(negative?(value), do: field(-value), else: field(value))
  defp field(value), do: Integer.mod(value, @field_prime)

  defp mod_power(base, exponent) do
    base
    |> :crypto.mod_pow(exponent, @field_prime)
    |> :binary.decode_unsigned()
  end
end
