defmodule Foxbus.Disruptions do
  @moduledoc """
  Application service: checks whether the configured line has an active
  notice via the configured source, and hands the result to the configured
  sink. Nothing else knows which adapters are wired in.
  """

  @spec check(String.t()) :: {:ok, boolean} | {:error, term}
  def check(line), do: source().disrupted?(line)

  @doc "Checks and publishes; returns what was found so the poller can log it."
  @spec check_and_publish(String.t()) :: {:ok, boolean} | {:error, term}
  def check_and_publish(line) do
    with {:ok, disrupted?} <- check(line),
         :ok <- sink().publish(disrupted?) do
      {:ok, disrupted?}
    end
  end

  defp source, do: Application.fetch_env!(:foxbus, :disruptions_source)
  defp sink, do: Application.fetch_env!(:foxbus, :disruptions_sink)
end
