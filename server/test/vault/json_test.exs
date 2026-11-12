defmodule Vault.JSONTest do
  use ExUnit.Case, async: true

  alias Vault.JSON
  alias Vault.JSON.Number

  @moduletag :m0
  @wire %{max_bytes: 4_096, max_depth: 8}
  @safe_integer 9_007_199_254_740_991

  test "decodes one strict object and preserves every original number lexeme" do
    input =
      ~S| {"a":-0,"b":[1E+000,{"child":-0.0e-001},[],{},"-0e1",20e-1],"c":9007199254740991.0} | <>
        "\r\n\t"

    assert JSON.decode_object(input, @wire) ==
             {:ok,
              %{
                "a" => {:json_number, "-0"},
                "b" => [
                  {:json_number, "1E+000"},
                  %{"child" => {:json_number, "-0.0e-001"}},
                  [],
                  %{},
                  "-0e1",
                  {:json_number, "20e-1"}
                ],
                "c" => {:json_number, "9007199254740991.0"}
              }}

    assert JSON.decode("-0", @wire) == {:ok, {:json_number, "-0"}}
    assert JSON.decode("10E-1", @wire) == {:ok, {:json_number, "10E-1"}}
    assert JSON.decode("null", @wire) == {:ok, nil}
    assert JSON.decode("true", @wire) == {:ok, true}
    assert JSON.decode("false", @wire) == {:ok, false}
    assert JSON.decode(~S|"text"|, @wire) == {:ok, "text"}
    assert JSON.decode_object("[]", @wire) == {:error, :root_type}
    assert JSON.decode_object("null", @wire) == {:error, :root_type}
    assert JSON.decode_object("true false", @wire) == {:error, :syntax}
  end

  test "rejects duplicates including decoded equivalents within ignored subtrees" do
    for input <- [
          ~S|{"type":1,"type":1}|,
          ~S|{"type":1,"type":2}|,
          ~S|{"type":1,"\u0074ype":2}|,
          ~S|{"ext":{"nested":[{"same":null,"same":null}]}}|,
          ~S|{"ext":{"nested":[{"same":null,"same":false}]}}|,
          ~S|{"ext":{"é":null,"\u00e9":false}}|,
          ~S|{"ext":{"\u0000":null,"\u0000":false}}|,
          ~S|{"\ud83d\udd11":null,"🔑":false}|
        ] do
      assert JSON.decode(input, @wire) == {:error, :duplicate_key}
    end

    assert JSON.decode(~S|{"a":{"x":1},"b":{"x":null},"é":true,"e\u0301":false}|, @wire) ==
             {:ok,
              %{
                "a" => %{"x" => {:json_number, "1"}},
                "b" => %{"x" => nil},
                "é" => true,
                "e\u0301" => false
              }}
  end

  test "normalizes malformed syntax errors without including input" do
    for input <- [
          "",
          " \r\n\t",
          "[] {}",
          "{}x",
          "{}\v",
          "{}\0",
          <<0xEF, 0xBB, 0xBF, ?{, ?}>>,
          ~S|{"k":true,}|,
          ~S|[true,]|,
          ~S|/* comment */ {}|,
          ~S|{"k":NaN}|,
          ~S|{"k":Infinity}|,
          ~S|{"k":-Infinity}|,
          ~S|{"k":1e}|,
          ~S|{"k":1E+}|,
          ~S|{"k":01}|,
          ~S|{"k":-01}|,
          ~S|{"k":+1}|,
          ~S|{"k":1.}|,
          ~S|{"k":.1}|,
          ~S|{"k":"\q"}|,
          ~S|{"k":"\u0x00"}|,
          ~S|{"k":"\ud800"}|,
          ~S|{"k":"\udfff"}|,
          ~S|{"k":"\ud800\u0041"}|,
          <<?", 0, ?">>,
          <<?", 0x1F, ?">>,
          <<?", ?\\>>
        ] do
      assert JSON.decode(input, @wire) == {:error, :syntax}, inspect(input)
    end
  end

  test "validates UTF-8 and preserves exact decoded Unicode and embedded NUL bytes" do
    for raw <- [
          <<0x80>>,
          <<0xC0, 0x80>>,
          <<0xE2, 0x82>>,
          <<0xED, 0xA0, 0x80>>,
          <<0xF4, 0x90, 0x80, 0x80>>,
          <<0xFF>>
        ] do
      assert JSON.decode(<<?", raw::binary, ?">>, @wire) == {:error, :utf8}
      assert JSON.decode(<<?{, ?", raw::binary, ?", ?:, ?1, ?}>>, @wire) == {:error, :utf8}
    end

    assert JSON.decode(~S|{"🔑":"\u0000é e\u0301 \udbff\udfff","\u0000":null}|, @wire) ==
             {:ok, %{"🔑" => "\0é e\u0301 \u{10FFFF}", "\0" => nil}}
  end

  test "checks byte and container depth limits at the limit and one past it" do
    for {max_bytes, max_depth} <- [{4_096, 8}, {8_192, 8}, {524_288, 12}, {262_144, 64}] do
      limits = %{max_bytes: max_bytes, max_depth: max_depth}
      value = :binary.copy("x", max_bytes - 8)
      input = ~s|{"x":"#{value}"}|

      assert byte_size(input) == max_bytes
      assert JSON.decode(input, limits) == {:ok, %{"x" => value}}
      assert JSON.decode(input <> " ", limits) == {:error, :size}

      nested = :binary.copy("[", max_depth) <> "0" <> :binary.copy("]", max_depth)
      assert JSON.decode(nested, limits) == {:ok, nest({:json_number, "0"}, max_depth)}
      assert JSON.decode(~s|{"x":#{nested}}|, limits) == {:error, :depth}
      assert JSON.decode(~s|{"x":#{nested}}|, %{limits | max_bytes: 1}) == {:error, :size}
    end

    assert JSON.decode(~S|"{[\"[\\"|, %{max_bytes: 32, max_depth: 0}) == {:ok, "{[\"[\\"}
    assert JSON.decode("{}", %{max_bytes: 2, max_depth: 0}) == {:error, :depth}
    assert JSON.decode(~S|"é"|, %{max_bytes: 3, max_depth: 0}) == {:error, :size}
    assert JSON.decode(~S|"é"|, %{max_bytes: 4, max_depth: 0}) == {:ok, "é"}
  end

  test "converts exact mathematical integers and checks inclusive signed and unsigned bounds" do
    for {input, expected} <- [
          {"1", 1},
          {"1.0", 1},
          {"1e0", 1},
          {"10e-1", 1},
          {"0.100E+0001", 1},
          {"-0", 0},
          {"-0.0e-123456", 0},
          {"1.25e2", 125},
          {"0.00001000e5", 1},
          {"9007199254740991.0", 9_007_199_254_740_991},
          {"900719925474099100e-2", 9_007_199_254_740_991}
        ] do
      assert Number.integer(parsed!(input), 0, @safe_integer) == {:ok, expected}
    end

    for input <- [
          "-1",
          "9007199254740990.5",
          "9007199254740991.0000000000000001",
          "9007199254740992",
          "1e-1",
          "1e16",
          "true",
          ~S|"1"|,
          "null"
        ] do
      assert Number.integer(parsed!(input), 0, @safe_integer) == {:error, :number}
    end

    assert Number.integer(parsed!("1.0"), 1, 1) == {:ok, 1}
    assert Number.integer(parsed!("-0"), 1, 1) == {:error, :number}
    assert Number.integer(parsed!("2"), 1, 1) == {:error, :number}
    assert Number.integer(parsed!("-90.0e-1"), -9, -2) == {:ok, -9}
    assert Number.integer(parsed!("-1"), -9, -2) == {:error, :number}
    assert Number.integer(parsed!("-10"), -9, -2) == {:error, :number}

    assert Number.integer(parsed!("-9007199254740991"), -@safe_integer, 0) ==
             {:ok, -9_007_199_254_740_991}

    assert Number.integer(parsed!("-9007199254740992"), -@safe_integer, 0) ==
             {:error, :number}

    assert Number.integer({:json_number, "1e-+"}, 0, 1) == {:error, :number}
    assert Number.integer({:json_number, "01"}, 0, 1) == {:error, :number}
  end

  test "bounds exponent work and accepts cancellation in long coefficients" do
    exponent = :binary.copy("9", 2_000)
    zeros = :binary.copy("0", 800)

    assert Number.integer(parsed!("-0e" <> exponent), 0, 1) == {:ok, 0}
    assert Number.integer(parsed!("0.0e-" <> exponent), 0, 1) == {:ok, 0}
    assert Number.integer(parsed!("1e" <> exponent), 0, @safe_integer) == {:error, :number}
    assert Number.integer(parsed!("1e-" <> exponent), 0, @safe_integer) == {:error, :number}
    assert Number.integer(parsed!("9" <> zeros <> "e-800"), 0, 9) == {:ok, 9}
    assert Number.integer(parsed!("0." <> zeros <> "9e801"), 0, 9) == {:ok, 9}

    assert Number.integer(parsed!("9" <> zeros <> "1e-801"), 0, @safe_integer) ==
             {:error, :number}
  end

  test "compares complete typed content with exact lengths and UTF-8 byte key order" do
    expected =
      <<"o", 2, "s", 1, "q", "a", 5, "n", "t", "f", "s", 2, "é", "d", 0, 1, "1", 0, 1, "2", "s",
        2, "é", "s", 1, "a">>

    assert comparison!(~S|{"é":"a","q":[null,true,false,"é",100.0]}|) == expected

    assert comparison!(~S|{ "q" : [null,true,false,"\u00e9",1e2], "\u00e9":"\u0061"}|) ==
             expected

    assert comparison!(~S|{"é":null,"z":true,"e\u0301":false}|) ==
             <<"o", 3, "s", 3, "e\u0301", "f", "s", 1, "z", "t", "s", 2, "é", "n">>

    refute comparison!(~S|{"x":{"extra":1}}|) == comparison!(~S|{"x":{"other":1}}|)
    refute comparison!(~S|{"x":{"extra":1}}|) == comparison!(~S|{"x":{"extra":"1"}}|)
    refute comparison!(~S|{"x":{"extra":1}}|) == comparison!(~S|{"x":{"extra":true}}|)
    refute comparison!(~S|{"x":null}|) == comparison!(~S|{}|)
    refute comparison!(~S|{"x":[null,1]}|) == comparison!(~S|{"x":[1,null]}|)
    refute comparison!(~S|{"x":"\u0000"}|) == comparison!(~S|{"x":""}|)
    refute comparison!(~S|{"x":"é"}|) == comparison!(~S|{"x":"e\u0301"}|)
  end

  test "compares exact decimal values with normalized coefficients and exponents" do
    for input <- ["1", "1.0", "10e-1", "1E+0"] do
      assert comparison!(input) == <<"d", 0, 1, "1", 0, 1, "0">>
    end

    assert JSON.comparison(1000, 4_096) == {:ok, <<"d", 0, 1, "1", 0, 1, "3">>}
    assert comparison!("-1.50000") == <<"d", 1, 2, "15", 1, 1, "1">>
    assert comparison!("0.01e1") == <<"d", 0, 1, "1", 1, 1, "1">>
    assert comparison!("1000e-1") == <<"d", 0, 1, "1", 0, 1, "2">>
    assert comparison!("-0.00e-12345678901234567890") == <<"d", 0, 1, "0", 0, 1, "0">>
    assert comparison!("1e999999") == <<"d", 0, 1, "1", 0, 6, "999999">>
    assert comparison!("10e999998") == <<"d", 0, 1, "1", 0, 6, "999999">>
    assert comparison!("1e999998") == <<"d", 0, 1, "1", 0, 6, "999998">>
    assert comparison!("1.5001") == <<"d", 0, 5, "15001", 1, 1, "4">>
  end

  test "carries and borrows across huge signed exponents without collapsing differences" do
    nines = :binary.copy("9", 128)
    power_of_ten = "1" <> :binary.copy("0", 128)

    assert comparison!("10e" <> nines) == <<"d", 0, 1, "1", 0, 129, 1, power_of_ten::binary>>

    assert comparison!("1.1e" <> power_of_ten) ==
             <<"d", 0, 2, "11", 0, 128, 1, nines::binary>>

    assert comparison!("1.1e-" <> nines) ==
             <<"d", 0, 2, "11", 1, 129, 1, power_of_ten::binary>>

    assert comparison!("10e-" <> power_of_ten) == <<"d", 0, 1, "1", 1, 128, 1, nines::binary>>

    assert comparison!(~s|{"ext":1e#{power_of_ten}}|) == comparison!(~s|{"ext":10e#{nines}}|)
    refute comparison!(~s|{"ext":1e#{power_of_ten}}|) == comparison!(~s|{"ext":1e#{nines}}|)
  end

  test "uses minimal ULEB128 and enforces the exact output allowance" do
    string = :binary.copy("x", 128)
    assert JSON.comparison(string, 128) == {:ok, <<"s", 128, 1, string::binary>>}

    nulls = :binary.copy("n", 128)
    assert JSON.comparison(List.duplicate(nil, 128), 512) == {:ok, <<"a", 128, 1, nulls::binary>>}

    value = :binary.copy("x", 65)
    expected = <<"o", 1, "s", 1, "x", "s", 65, value::binary>>
    assert byte_size(expected) == 72
    assert JSON.comparison(%{"x" => value}, 1) == {:ok, expected}
    assert JSON.comparison(%{"x" => value <> "x"}, 1) == {:error, :resource}

    input = "[" <> :binary.copy("1,", 2_046) <> "1 ]"
    expected = <<"a", 255, 15>> <> :binary.copy(<<"d", 0, 1, "1", 0, 1, "0">>, 2_047)
    assert byte_size(input) == 4_096
    assert comparison!(input) == expected
  end

  test "canonical encoding sorts recursively and emits exact integer and string bytes" do
    value = %{
      "z" => ["🔑/é e\u0301", false, nil, -27],
      "a" => %{
        "b" => 9_007_199_254_740_991,
        "a" => <<?", ?\\, 0, 1, 8, 9, 10, 11, 12, 13, 14, 15, 16, 26, 31>>
      },
      "Z" => true,
      "N\0" => 0
    }

    assert JSON.canonical(value) ==
             {:ok,
              ~S|{"N\u0000":0,"Z":true,"a":{"a":"\"\\\u0000\u0001\b\t\n\u000b\f\r\u000e\u000f\u0010\u001a\u001f","b":9007199254740991},"z":["🔑/é é",false,null,-27]}|}

    assert JSON.canonical([]) == {:ok, "[]"}
    assert JSON.canonical(%{}) == {:ok, "{}"}
    assert JSON.canonical(nil) == {:ok, "null"}
  end

  test "canonical encoding rejects values outside the integer-only JSON domain" do
    for value <- [
          1.0,
          {:json_number, "1"},
          %{"x" => {:json_number, "1"}},
          :null,
          %{x: 1},
          %{"é" => 1},
          %{"value" => %URI{}},
          [1 | 2]
        ] do
      assert JSON.canonical(value) == {:error, :shape}
    end

    assert JSON.canonical(%{"x" => <<0xFF>>}) == {:error, :utf8}
  end

  test "decoding, comparison and canonical encoding start no application or Vault process" do
    names = [Vault.Repo, VaultWeb.Endpoint, Vault.GameStore, Vault.SimulatedBox.Runtime]
    before = MapSet.new(Application.started_applications())
    refute Enum.any?(before, fn {name, _description, _version} -> name in [:vault, :phoenix] end)
    assert Enum.map(names, &Process.whereis/1) == [nil, nil, nil, nil]

    assert JSON.decode(~S|{"n":10.0}|, @wire) == {:ok, %{"n" => {:json_number, "10.0"}}}
    assert comparison!(~S|{"n":10.0}|) == <<"o", 1, "s", 1, "n", "d", 0, 1, "1", 0, 1, "1">>
    assert JSON.canonical(%{"n" => 10}) == {:ok, ~S|{"n":10}|}

    assert MapSet.new(Application.started_applications()) == before
    assert Enum.map(names, &Process.whereis/1) == [nil, nil, nil, nil]
  end

  defp nest(value, 0), do: value
  defp nest(value, depth), do: [nest(value, depth - 1)]

  defp parsed!(input) do
    assert {:ok, value} = JSON.decode(input, @wire)
    value
  end

  defp comparison!(input) do
    assert {:ok, comparison} = JSON.comparison(parsed!(input), @wire.max_bytes)
    comparison
  end
end
