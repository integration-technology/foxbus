defmodule Foxbus.Disruptions do
  @moduledoc """
  Application service: checks, for one stop, whether any of its watched
  lines has an active notice that applies to it, via its configured
  provider, and hands the notice's own text (or nil) to the configured
  sink. Nothing else knows which adapters are wired in. Only called for a
  stop whose provider actually has this capability — see
  `Foxbus.Ports.Provider.disruptions?/0`.
  """

  @spec check(module, [String.t()], String.t()) :: {:ok, String.t() | nil} | {:error, term}
  def check(provider, lines, stop_id), do: provider.disrupted?(lines, stop_id)

  @doc "Checks and publishes; returns what was found so the poller can log it."
  @spec check_and_publish(module, atom, [String.t()], String.t()) ::
          {:ok, String.t() | nil} | {:error, term}
  def check_and_publish(provider, stop, lines, stop_id) do
    with {:ok, explanation} <- check(provider, lines, stop_id),
         :ok <- sink().publish_disruption(stop, explanation) do
      {:ok, explanation}
    end
  end

  defp sink, do: Application.fetch_env!(:foxbus, :disruptions_sink)
end
