defmodule Foxbus.ScreenPower do
  @moduledoc """
  The screen's sleep/wake behaviour — how long idle before it sleeps, and
  whether it wakes on someone approaching — set from the settings UI and
  kept in `NestGen2.Storage` so it survives a restart. `NestGen2.Power`
  itself always starts from its own defaults (30 s, every wake source) on
  every boot, with no memory of an earlier session's choice, so
  `apply_saved/0` is meant to be called once at start to put the saved
  choice back.

  The dial and button are never offered as something to turn off: with
  `wake_on_approach?: false` and no way to press the (sleeping) screen, the
  only way back would be a reboot. They're folded permanently into
  `wake_sources` instead of being a UI choice.

  Before nest_gen2 0.3.0 this was a hand-rolled file, `screen_power.exs`
  next to the other device assets. `migrate_from_file/0`, called once at
  start (see `Foxbus.Application`), carries an existing install's choice
  over into Storage without anything done by hand, then leaves the old file
  alone — it only acts when Storage doesn't already have a value, so it's
  safe to call on every boot.
  """

  alias NestGen2.{Power, Storage}

  @default_idle_timeout_ms 30_000
  @default_wake_on_approach? true
  @always_on_sources [:dial, :button]
  @approach_sources [:motion, :light]
  @storage_key :screen

  @type t :: %{idle_timeout_ms: pos_integer | :infinity, wake_on_approach?: boolean}

  @doc "The saved choice, or NestGen2.Power's own defaults if nothing's been saved yet."
  @spec load() :: t
  def load, do: Storage.get(@storage_key, defaults(), app: :foxbus)

  @doc "Applies the saved choice to NestGen2.Power — meant to be called once, at start."
  @spec apply_saved() :: :ok
  def apply_saved, do: load() |> apply_to_power()

  @doc "Applies a new choice to NestGen2.Power and saves it, so it survives a restart."
  @spec apply(t) :: :ok
  def apply(choice) do
    apply_to_power(choice)
    save(choice)
  end

  defp apply_to_power(%{idle_timeout_ms: idle_timeout_ms, wake_on_approach?: wake_on_approach?}) do
    Power.set_idle_timeout(idle_timeout_ms)
    Power.set_wake_sources(wake_sources(wake_on_approach?))
  end

  defp wake_sources(true), do: @always_on_sources ++ @approach_sources
  defp wake_sources(false), do: @always_on_sources

  @doc false
  # Public (only) so it's testable on its own — apply/1 always touches
  # NestGen2.Power too, which isn't running under `mix test --no-start`.
  @spec save(t) :: :ok | {:error, term}
  def save(choice), do: Storage.put(@storage_key, choice, app: :foxbus)

  @doc """
  One-time migration from the pre-0.3.0 `screen_power.exs` file into
  Storage. A no-op once Storage already has a value, so it's safe to call
  on every boot; the old file, if any, is left untouched either way.
  """
  @spec migrate_from_file() :: :ok
  def migrate_from_file do
    if Storage.get(@storage_key, nil, app: :foxbus) == nil do
      case read_old_file() do
        {:ok, choice} -> save(choice) |> ignore_error()
        :error -> :ok
      end
    else
      :ok
    end
  end

  defp ignore_error(_), do: :ok

  defp read_old_file do
    path = old_path()

    with true <- File.exists?(path),
         {term, _bindings} <- Code.eval_file(path),
         true <- Keyword.keyword?(term) do
      {:ok,
       %{
         idle_timeout_ms: Keyword.get(term, :idle_timeout_ms, @default_idle_timeout_ms),
         wake_on_approach?: Keyword.get(term, :wake_on_approach?, @default_wake_on_approach?)
       }}
    else
      _ -> :error
    end
  rescue
    # A malformed old file shouldn't be able to stop the app from booting.
    _ -> :error
  end

  defp defaults,
    do: %{
      idle_timeout_ms: @default_idle_timeout_ms,
      wake_on_approach?: @default_wake_on_approach?
    }

  defp old_path do
    Application.get_env(:foxbus, :screen_power_path) ||
      Path.join(Application.get_env(:foxbus, :assets_dir, "."), "screen_power.exs")
  end
end
