defmodule Vault.Protocol.V1 do
  @moduledoc """
  Structural validation and allowlisting for the fifteen version-one wire types.

  This module handles JSON shape and exact values. The connection and game owners
  handle identity, authorization, freshness and state.
  """

  alias Vault.JSON
  alias Vault.JSON.Number

  @safe_integer 9_007_199_254_740_991
  @roles ~w(a b c d)
  @phases ~w(lobby maze seal solved)
  @runes ~w(star moon sun wave)
  @moves ~w(up down left right)
  @pause_reasons ~w(operator controller_offline box_offline recovery)
  @box_statuses ~w(not_requested accepted motion_complete position_confirmed uncertain failed)
  @positions ~w(locked released unknown)
  @confirmation_bases ~w(endstop manual_verified)
  @position_bases @confirmation_bases ++ ["unverified"]
  @failures ~w(unknown_command not_armed unknown_position stale_binding busy history_full
               connection_lost reboot_interrupted freshness_lost travel_timeout limit_fault driver_fault)
  @empty_applied ~w(role_released snapshot_sent)
  @empty_rejected ~w(result_expired wall out_of_bounds wrong_axis role_busy stale_controller
                     not_authorized stale_session)
  @heartbeat_codes ~w(ok paused stale_sample stale_challenge stale_context must_release)
  @light_modes ~w(idle progress paused success error)
  @sounds ~w(none tick success error)

  @spec validate(map()) :: {:ok, map()} | {:error, JSON.reason()}
  def validate(%{"v" => version, "type" => type} = value) do
    with {:ok, 1} <- integer(version, 1, 1),
         {:ok, message} <- message(type, value),
         :ok <- bound_strings(value) do
      {:ok, Map.merge(message, %{"v" => 1, "type" => type})}
    end
  end

  def validate(_), do: {:error, :shape}

  defp message("hello", %{"device_class" => class} = value) when class in ~w(controller box) do
    capabilities =
      if class == "controller", do: &controller_capabilities/1, else: &box_capabilities/1

    fields(value,
      device_id: &id/1,
      boot_id: &id/1,
      firmware_version: &text/1,
      device_class: &accept/1,
      capabilities: capabilities
    )
  end

  defp message("welcome", value) do
    connection(value,
      session_id: &id/1,
      round_id: &seq/1,
      puzzle_revision: &seq/1,
      required_roles: &roles/1,
      allowed_roles: &roles/1,
      assigned_role: &null/1,
      heartbeat_interval_ms: &integer(&1, 100, 100),
      input_lease_ms: &integer(&1, 400, 400),
      peer_dead_ms: &integer(&1, 1500, 1500)
    )
  end

  defp message("command", %{"action" => "claim_role"} = value) do
    command(value, payload: fn payload -> exact(payload, role: &role/1) end)
  end

  defp message("command", %{"action" => "request_snapshot"} = value) do
    command(value, payload: &exact(&1, []))
  end

  defp message("command", %{"action" => "release_role"} = value) do
    command(value, role: &role/1, control_epoch: &seq/1, payload: &exact(&1, []))
  end

  defp message("command", %{"action" => "move"} = value) do
    play_command(value, fn payload ->
      exact(payload, direction: &enum(&1, @moves), expected_board_version: &version/1)
    end)
  end

  defp message("command", %{"action" => "select_rune"} = value) do
    play_command(value, fn payload -> exact(payload, rune: &rune/1) end)
  end

  defp message("command_result", %{"code" => code} = value) do
    with {:ok, status, data_fields} <- result(code) do
      connection(value,
        command_seq: &seq/1,
        status: &enum(&1, [status]),
        code: &accept/1,
        session_id: &id/1,
        state_revision: &version/1,
        data: &exact(&1, data_fields)
      )
    end
  end

  defp message("snapshot", %{"projection" => "controller"} = value) do
    with {:ok, snapshot} <-
           snapshot(value,
             role: &role/1,
             control_epoch: &seq/1,
             board_version: &version/1,
             maze: fn item -> nullable(item, &maze/1) end,
             seal: fn item -> nullable(item, &seal/1) end,
             hold: &hold/1
           ),
         :ok <- controller_phase(snapshot),
         :ok <- controller_pause(snapshot),
         :ok <- controller_role(snapshot) do
      {:ok, snapshot}
    end
  end

  defp message("snapshot", %{"projection" => projection} = value)
       when projection in ~w(public box) do
    if Enum.any?(~w(maze seal hold board_version), &Map.has_key?(value, &1)) do
      {:error, :shape}
    else
      snapshot(value, role: &null/1, control_epoch: &null/1)
    end
  end

  defp message("heartbeat_request", value), do: connection(value, heartbeat_seq: &seq/1)

  defp message("heartbeat", value) do
    connection(value,
      heartbeat_seq: &seq/1,
      input_seq: &seq/1,
      input: fn item -> nullable(item, &input/1) end
    )
  end

  defp message("heartbeat_ack", value) do
    connection(value,
      heartbeat_seq: &seq/1,
      input_seq: &seq/1,
      input_accepted: &boolean/1,
      code: &enum(&1, @heartbeat_codes)
    )
  end

  defp message(type, value) when type in ~w(box_arm box_disarm),
    do: box_binding(value, arm_id: &id/1)

  defp message("box_command", value) do
    box_binding(value,
      arm_id: &id/1,
      heartbeat_seq: &seq/1,
      command_id: &id/1,
      action: &enum(&1, ["set_latch"]),
      target: &enum(&1, ["released"])
    )
  end

  defp message("box_status", value) do
    with {:ok, status} <-
           box_binding(value, [
             {:status_seq, &seq/1},
             {:command_session_id, fn item -> nullable(item, &id/1) end}
             | box_report_fields(@box_statuses)
           ]),
         :ok <- command_session(status),
         :ok <- confirmation(status) do
      {:ok, status}
    end
  end

  defp message("box_status_ack", value) do
    with {:ok, ack} <-
           connection(value,
             status_seq: &seq/1,
             accepted: &boolean/1,
             code: &enum(&1, ~w(ok stale_status))
           ),
         true <- ack["accepted"] == (ack["code"] == "ok") do
      {:ok, ack}
    else
      false -> {:error, :shape}
      error -> error
    end
  end

  defp message("box_query", value),
    do: connection(value, command_id: fn item -> nullable(item, &id/1) end)

  defp message("box_feedback", value) do
    box_binding(value,
      feedback_seq: &seq/1,
      light_mode: &enum(&1, @light_modes),
      progress_percent: &integer(&1, 0, 100),
      sound: &enum(&1, @sounds),
      ttl_ms: &integer(&1, 100, 1500)
    )
  end

  defp message(_, _), do: {:error, :shape}

  defp connection(value, fields), do: fields(value, [{:connection_id, &id/1} | fields])

  defp box_binding(value, fields) do
    connection(value, [{:box_boot_id, &id/1}, {:session_id, &id/1} | fields])
  end

  defp command(value, fields) do
    connection(value, [
      {:command_seq, &seq/1},
      {:session_id, &id/1},
      {:action, &accept/1}
      | fields
    ])
  end

  defp play_command(value, payload) do
    command(value,
      round_id: &seq/1,
      puzzle_revision: &seq/1,
      role: &role/1,
      control_epoch: &seq/1,
      payload: payload
    )
  end

  defp result("role_claimed"), do: {:ok, "applied", [role: &role/1, control_epoch: &seq/1]}
  defp result("moved"), do: {:ok, "applied", position_fields()}
  defp result("rune_selected"), do: {:ok, "applied", [selected_rune: &rune/1]}
  defp result("stale_board"), do: {:ok, "rejected", position_fields()}
  defp result("stale_round"), do: {:ok, "rejected", [round_id: &seq/1]}
  defp result("stale_puzzle"), do: {:ok, "rejected", [puzzle_revision: &seq/1]}
  defp result("paused"), do: {:ok, "rejected", [pause_reasons: &pause_reasons/1]}
  defp result("wrong_phase"), do: {:ok, "rejected", [phase: &enum(&1, @phases)]}
  defp result("seq_gap"), do: {:ok, "rejected", [expected_command_seq: &seq/1]}
  defp result(code) when code in @empty_applied, do: {:ok, "applied", []}
  defp result(code) when code in @empty_rejected, do: {:ok, "rejected", []}
  defp result(_), do: {:error, :shape}

  defp position_fields, do: [position: &cell/1, board_version: &version/1]

  defp controller_capabilities(value) do
    fields(value,
      touch: &enum(&1, [true]),
      screen_width: &integer(&1, 1, 4096),
      screen_height: &integer(&1, 1, 4096),
      max_message_bytes: &integer(&1, 8192, @safe_integer)
    )
  end

  defp box_capabilities(value) do
    fields(value,
      latch: &enum(&1, ["stepper"]),
      home_sensor: &boolean/1,
      released_sensor: &boolean/1,
      led_count: &integer(&1, 0, 256),
      buzzer: &boolean/1,
      max_message_bytes: &integer(&1, 8192, @safe_integer)
    )
  end

  defp snapshot(value, fields) do
    connection(value, [
      {:session_id, &id/1},
      {:round_id, &seq/1},
      {:puzzle_revision, &seq/1},
      {:state_revision, &version/1},
      {:phase, &enum(&1, @phases)},
      {:paused, &boolean/1},
      {:pause_reasons, &pause_reasons/1},
      {:required_roles, &roles/1},
      {:peers, fn items -> array(items, 0, 4, &peer/1, false) end},
      {:box, &box_projection/1},
      {:projection, &accept/1}
      | fields
    ])
  end

  defp maze(value) do
    exact(value,
      rows: &integer(&1, 4, 4),
      cols: &integer(&1, 4, 4),
      position: &cell/1,
      goal: &cell/1,
      wall_kind: &enum(&1, ~w(right bottom)),
      walls: fn items -> array(items, 0, 12, &cell/1, true) end,
      allowed_moves: &array(&1, 2, 2, fn move -> enum(move, @moves) end, true)
    )
  end

  defp seal(value) do
    exact(value,
      clue_for_role: &role/1,
      clue_rune: &rune/1,
      selected_rune: fn item -> nullable(item, &rune/1) end,
      partner_held: &boolean/1
    )
  end

  defp hold(value) do
    exact(value,
      active: &boolean/1,
      qualified: &boolean/1,
      elapsed_ms: &integer(&1, 0, 2000),
      duration_ms: &integer(&1, 2000, 2000),
      fresh_press_required: &boolean/1
    )
  end

  defp controller_phase(%{"phase" => "maze", "maze" => maze, "seal" => nil, "hold" => hold})
       when is_map(maze),
       do: inactive_hold(hold)

  defp controller_phase(%{"phase" => "seal", "maze" => nil, "seal" => seal, "hold" => hold})
       when is_map(seal) do
    if not hold["qualified"] and hold["elapsed_ms"] < 2000, do: :ok, else: {:error, :shape}
  end

  defp controller_phase(%{"phase" => "lobby", "maze" => nil, "seal" => nil, "hold" => hold}),
    do: inactive_hold(hold)

  defp controller_phase(%{
         "phase" => "solved",
         "maze" => nil,
         "seal" => nil,
         "hold" => %{
           "active" => false,
           "qualified" => true,
           "elapsed_ms" => 2000,
           "fresh_press_required" => false
         }
       }),
       do: :ok

  defp controller_phase(_), do: {:error, :shape}

  defp controller_pause(%{"paused" => true, "phase" => phase, "hold" => hold})
       when phase != "solved",
       do: inactive_hold(hold)

  defp controller_pause(_), do: :ok

  defp inactive_hold(%{"active" => false, "qualified" => false, "elapsed_ms" => 0}), do: :ok
  defp inactive_hold(_), do: {:error, :shape}

  defp controller_role(%{"role" => "a", "maze" => maze, "seal" => seal}) do
    role_projection(maze, seal, "right", ~w(up down), "b")
  end

  defp controller_role(%{"role" => "b", "maze" => maze, "seal" => seal}) do
    role_projection(maze, seal, "bottom", ~w(left right), "a")
  end

  defp controller_role(_), do: :ok

  defp role_projection(maze, seal, wall_kind, moves, partner) do
    if (is_nil(maze) or (maze["wall_kind"] == wall_kind and maze["allowed_moves"] == moves)) and
         (is_nil(seal) or seal["clue_for_role"] == partner) do
      :ok
    else
      {:error, :shape}
    end
  end

  defp peer(value) do
    with {:ok, peer} <-
           exact(value,
             role: &role/1,
             connected: &boolean/1,
             source: &enum(&1, ~w(cyd browser none)),
             held: &boolean/1
           ),
         :ok <- peer_consistency(peer) do
      {:ok, peer}
    end
  end

  defp peer_consistency(%{"connected" => false, "held" => true}), do: {:error, :shape}
  defp peer_consistency(%{"source" => "none", "connected" => true}), do: {:error, :shape}
  defp peer_consistency(_), do: :ok

  defp input(value) do
    with {:ok, input} <-
           exact(value,
             session_id: &id/1,
             round_id: &seq/1,
             puzzle_revision: &seq/1,
             role: &role/1,
             control_epoch: &seq/1,
             pressed: &boolean/1,
             press_id: fn item -> nullable(item, &seq/1) end
           ),
         true <- input["pressed"] == is_integer(input["press_id"]) do
      {:ok, input}
    else
      false -> {:error, :shape}
      error -> error
    end
  end

  defp box_report_fields(statuses) do
    [
      command_id: fn item -> nullable(item, &id/1) end,
      release_status: &enum(&1, statuses),
      motor_active: &boolean/1,
      latch_position: &enum(&1, @positions),
      position_basis: &enum(&1, @position_bases),
      readiness: &readiness/1,
      failure_code: &nullable(&1, fn failure -> enum(failure, @failures) end),
      command_confirmation: fn item -> nullable(item, &command_confirmation/1) end
    ]
  end

  defp box_projection(value) do
    with {:ok, box} <-
           exact(value, [
             {:connected, &boolean/1},
             {:simulated, &boolean/1}
             | box_report_fields(["pending" | @box_statuses])
           ]),
         :ok <- confirmation(box) do
      {:ok, box}
    end
  end

  defp readiness(value) do
    with {:ok, readiness} <-
           exact(value,
             arm_id: fn item -> nullable(item, &id/1) end,
             armed_session_id: fn item -> nullable(item, &id/1) end,
             calibration_valid: &boolean/1,
             start_verified: &boolean/1
           ),
         :ok <- arm_consistency(readiness) do
      {:ok, readiness}
    end
  end

  defp arm_consistency(%{"arm_id" => nil, "armed_session_id" => nil}), do: :ok

  defp arm_consistency(%{
         "arm_id" => arm_id,
         "armed_session_id" => session_id,
         "calibration_valid" => true,
         "start_verified" => true
       })
       when is_binary(arm_id) and is_binary(session_id),
       do: :ok

  defp arm_consistency(_), do: {:error, :shape}

  defp command_confirmation(value) do
    exact(value, basis: &enum(&1, @confirmation_bases), box_boot_id: &id/1)
  end

  defp confirmation(%{"release_status" => "position_confirmed", "simulated" => true}),
    do: {:error, :shape}

  defp confirmation(%{"release_status" => "position_confirmed", "command_confirmation" => record})
       when is_map(record),
       do: :ok

  defp confirmation(%{"release_status" => status, "command_confirmation" => nil})
       when status != "position_confirmed",
       do: :ok

  defp confirmation(_), do: {:error, :shape}

  defp command_session(%{"command_id" => nil, "command_session_id" => session})
       when not is_nil(session),
       do: {:error, :shape}

  defp command_session(_), do: :ok

  defp exact(value, spec) when is_map(value) and map_size(value) == length(spec),
    do: fields(value, spec)

  defp exact(_, _), do: {:error, :shape}

  defp fields(value, spec) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(spec, {:ok, %{}}, fn {name, validator}, {:ok, accepted} ->
      key = Atom.to_string(name)

      with {:ok, field} <- Map.fetch(value, key),
           {:ok, normalized} <- validator.(field) do
        {:cont, {:ok, Map.put(accepted, key, normalized)}}
      else
        :error -> {:halt, {:error, :shape}}
        error -> {:halt, error}
      end
    end)
  end

  defp fields(_, _), do: {:error, :shape}

  defp array(value, min, max, element, unique) when is_list(value) do
    length = length(value)

    if length >= min and length <= max do
      value
      |> Enum.reduce_while({:ok, []}, fn item, {:ok, accepted} ->
        case element.(item) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | accepted]}}
          error -> {:halt, error}
        end
      end)
      |> array_order(unique, length)
    else
      {:error, :shape}
    end
  end

  defp array(_, _, _, _, _), do: {:error, :shape}

  defp array_order({:ok, items}, unique, length) do
    if unique and MapSet.size(MapSet.new(items)) != length do
      {:error, :shape}
    else
      {:ok, Enum.reverse(items)}
    end
  end

  defp array_order(error, _, _), do: error

  defp roles(value), do: array(value, 0, 4, &role/1, true)
  defp pause_reasons(value), do: array(value, 0, 4, &enum(&1, @pause_reasons), true)
  defp seq(value), do: integer(value, 1, @safe_integer)
  defp version(value), do: integer(value, 0, @safe_integer)
  defp cell(value), do: integer(value, 0, 15)
  defp role(value), do: enum(value, @roles)
  defp rune(value), do: enum(value, @runes)
  defp accept(value), do: {:ok, value}

  defp integer(value, min, max) when is_integer(value) and value >= min and value <= max,
    do: {:ok, value}

  defp integer(value, min, max), do: Number.integer(value, min, max)

  defp nullable(nil, _), do: {:ok, nil}
  defp nullable(value, validator), do: validator.(value)
  defp null(nil), do: {:ok, nil}
  defp null(_), do: {:error, :shape}

  defp boolean(value) when is_boolean(value), do: {:ok, value}
  defp boolean(_), do: {:error, :shape}

  defp enum(value, values) do
    if value in values, do: {:ok, value}, else: {:error, :shape}
  end

  defp id(value) when is_binary(value) and byte_size(value) in 1..64 do
    if Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, value), do: {:ok, value}, else: {:error, :shape}
  end

  defp id(_), do: {:error, :shape}

  defp text(value) when is_binary(value), do: accept(value)
  defp text(_), do: {:error, :shape}

  # This also visits extension keys/values without interpreting their shape or numbers.
  defp bound_strings(value) when is_binary(value), do: string_scalars(value, 128)

  defp bound_strings(value) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, :ok, fn {key, item}, :ok ->
      with true <- is_binary(key),
           :ok <- bound_strings(key),
           :ok <- bound_strings(item) do
        {:cont, :ok}
      else
        false -> {:halt, {:error, :shape}}
        error -> {:halt, error}
      end
    end)
  end

  defp bound_strings(value) when is_list(value) do
    Enum.reduce_while(value, :ok, fn item, :ok ->
      case bound_strings(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp bound_strings(_value), do: :ok

  defp string_scalars(<<>>, _remaining), do: :ok

  defp string_scalars(<<_scalar::utf8, rest::binary>>, remaining) when remaining > 0,
    do: string_scalars(rest, remaining - 1)

  defp string_scalars(_, _), do: {:error, :shape}
end
