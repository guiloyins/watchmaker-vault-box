defmodule Vault.GameStore.Checkpoint do
  @moduledoc "The strict version-one checkpoint. Live inputs and grants never enter it."

  alias Vault.GameStore.Codec

  @fields ~w(schema_version game_id session_id round_id puzzle_revision state_revision phase position board_version selected_runes paused pause_reasons required_roles active_time_ms release_command_id)a
  @phases ~w(lobby maze seal solved)a
  @runes ~w(star moon sun wave)a
  @pause_reasons ~w(operator controller_offline box_offline recovery)a

  def initial(game_id, session_id) do
    %{
      schema_version: 1,
      game_id: game_id,
      session_id: session_id,
      round_id: 1,
      puzzle_revision: 1,
      state_revision: 0,
      phase: :lobby,
      position: 12,
      board_version: 0,
      selected_runes: %{a: nil, b: nil},
      paused: false,
      pause_reasons: [],
      required_roles: [:a, :b],
      active_time_ms: 0,
      release_command_id: nil
    }
  end

  def encode(%{game_id: game_id} = checkpoint) do
    with true <- valid?(checkpoint, game_id),
         {:ok, json} <- Codec.encode(checkpoint, 8192) do
      {:ok, json}
    else
      _ -> {:error, :invalid_checkpoint}
    end
  end

  def encode(_), do: {:error, :invalid_checkpoint}

  def decode(json, game_id) do
    with {:ok, object} <- Codec.decode(json, 8192),
         true <- map_size(object) == length(@fields),
         true <- Enum.all?(@fields, &Map.has_key?(object, Atom.to_string(&1))),
         checkpoint = Map.new(@fields, &{&1, Map.fetch!(object, Atom.to_string(&1))}),
         %{
           phase: phase,
           selected_runes: %{"a" => a, "b" => b} = selected,
           pause_reasons: reasons,
           required_roles: ["a", "b"]
         } <- checkpoint,
         true <- map_size(selected) == 2 and is_list(reasons),
         {:ok, phase} <- allowed(phase, @phases),
         {:ok, a} <- allowed_rune(a),
         {:ok, b} <- allowed_rune(b),
         {:ok, reasons} <- allowed_reasons(reasons),
         typed = %{
           checkpoint
           | phase: phase,
             selected_runes: %{a: a, b: b},
             pause_reasons: reasons,
             required_roles: [:a, :b]
         },
         true <- valid?(typed, game_id) do
      {:ok, typed}
    else
      _ -> {:error, :invalid_checkpoint}
    end
  end

  defp valid?(
         %{
           schema_version: 1,
           game_id: game_id,
           session_id: session,
           round_id: round,
           puzzle_revision: puzzle,
           state_revision: revision,
           phase: phase,
           position: position,
           board_version: board,
           selected_runes: %{a: a, b: b} = selected,
           paused: paused,
           pause_reasons: reasons,
           required_roles: [:a, :b],
           active_time_ms: active,
           release_command_id: release
         } = checkpoint,
         game_id
       ) do
    map_size(checkpoint) == length(@fields) and
      Codec.id?(game_id) and Codec.id?(session) and Codec.p?(round) and Codec.p?(puzzle) and
      Codec.n?(revision) and Codec.n?(board) and Codec.n?(active) and
      phase in @phases and is_integer(position) and position in 0..15 and
      (phase not in [:seal, :solved] or position == 3) and
      map_size(selected) == 2 and a in [nil | @runes] and b in [nil | @runes] and
      is_boolean(paused) and is_list(reasons) and Enum.uniq(reasons) == reasons and
      Enum.all?(reasons, &(&1 in @pause_reasons)) and paused == (reasons != []) and
      if(phase == :solved, do: Codec.id?(release), else: is_nil(release))
  end

  defp valid?(_, _), do: false

  defp allowed(value, options) do
    case Enum.find(options, &(Atom.to_string(&1) == value)) do
      nil -> {:error, :value}
      option -> {:ok, option}
    end
  end

  defp allowed_rune(nil), do: {:ok, nil}
  defp allowed_rune(value), do: allowed(value, @runes)

  defp allowed_reasons(reasons) do
    Enum.reduce_while(reasons, {:ok, []}, fn reason, {:ok, result} ->
      case allowed(reason, @pause_reasons) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | result]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end
end
