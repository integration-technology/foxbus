defmodule Foxbus.ScreenPower do
  @moduledoc """
  The screen's sleep/wake behaviour — how long idle before it sleeps, and
  whether it wakes on someone approaching — set from the settings UI and
  kept on disk so it survives a restart. `NestGen2.Power` itself always
  starts from its own defaults (30 s, every wake source) on every boot, with
  no memory of an earlier session's choice, so `apply_saved/0` is meant to
  be called once at start to put the saved choice back.

  The dial and button are never offered as something to turn off: with
  `wake_on_approach?: false` and no way to press the (sleeping) screen, the
  only way back would be a reboot. They're folded permanently into
  `wake_sources` instead of being a UI choice.

  The file, like `Foxbus.Config`'s, is a plain keyword list evaluated with
  `Code.eval_file/1` — local device config, not user input, trusted the same
  way. Unlike `Foxbus.Config`, this one is written by foxbus itself (from
  the settings UI), not hand-edited — each write is followed by `sync`, on
  the same reasoning as `deploy_app.sh`'s own: a torn write from a power
  loss right after should not be able to corrupt the flash.
  """

  alias NestGen2.Power

  @default_idle_timeout_ms 30_000
  @default_wake_on_approach? true
  @always_on_sources [:dial, :button]
  @approach_sources [:motion, :light]

  @type t :: %{idle_timeout_ms: pos_integer | :infinity, wake_on_approach?: boolean}

  @doc "The saved choice, or NestGen2.Power's own defaults if nothing's been saved yet."
  @spec load() :: t
  def load do
    path = path()

    with true <- File.exists?(path),
         {term, _bindings} <- Code.eval_file(path),
         true <- Keyword.keyword?(term) do
      %{
        idle_timeout_ms: Keyword.get(term, :idle_timeout_ms, @default_idle_timeout_ms),
        wake_on_approach?: Keyword.get(term, :wake_on_approach?, @default_wake_on_approach?)
      }
    else
      _ -> defaults()
    end
  rescue
    # A malformed file shouldn't be able to stop the app from booting —
    # fall back to the defaults instead, same as Foxbus.Config.
    _ -> defaults()
  end

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
  @spec save(t) :: :ok
  def save(choice) do
    content = inspect(Keyword.new(choice), pretty: true, limit: :infinity)
    File.write!(path(), content)
    System.cmd("sync", [])
    :ok
  end

  defp defaults,
    do: %{
      idle_timeout_ms: @default_idle_timeout_ms,
      wake_on_approach?: @default_wake_on_approach?
    }

  defp path do
    Application.get_env(:foxbus, :screen_power_path) || default_path()
  end

  defp default_path do
    Path.join(Application.get_env(:foxbus, :assets_dir, "."), "screen_power.exs")
  end
end
